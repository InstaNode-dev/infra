###############################################################################
# AKS control plane identity and its role assignments.
#
# COST: $0.00/mo - managed identities and role assignments are free.
#
# WHY A USER-ASSIGNED IDENTITY RATHER THAN SYSTEM-ASSIGNED
#
# This is not a style preference; it is the documented requirement for how this
# cluster is built. Microsoft Learn, "Overview of Managed Identities in AKS"
# (learn.microsoft.com/azure/aks/managed-identity-overview, retrieved
# 2026-08-09):
#
#   "If you're not using the Azure CLI, but you're using your own VNet, attached
#    Azure disks, static IP address, route table, or user-assigned kubelet
#    identity where those resources are outside of the worker node resource
#    group, we recommend using a user-assigned managed identity for the control
#    plane and manually performing the required role assignment using the
#    principal ID of that identity."
#
# We are using Terraform (not the CLI, which silently creates these role
# assignments for you), with a BYO VNet and a BYO static public IP, both outside
# the node resource group. That is exactly the case the doc calls out.
#
# The concrete failure this avoids: with a system-assigned identity the
# principal does not exist until the cluster is created, so the role assignments
# can only be applied AFTER creation. Cluster creation itself needs to place
# node NICs in the BYO subnet. A user-assigned identity is created first, gets
# its grants first, and then the cluster is built against an identity that is
# already authorised.
#
# It also survives cluster replacement: if the cluster is ever recreated (e.g.
# changing network_policy_engine), the identity and its grants persist, so the
# static IP and subnet permissions do not have to be re-granted.
#
# KUBELET IDENTITY: deliberately not specified. Per the same document, "If you
# don't specify a user-assigned managed identity for kubelet, AKS creates a
# user-assigned kubelet identity in the node resource group." The
# Managed Identity Operator role is only required "for a user-assigned kubelet
# identity OUTSIDE the default worker node resource group" - which is not the
# case here, so no extra grant is needed.
###############################################################################

resource "azurerm_user_assigned_identity" "aks_control_plane" {
  name                = local.control_plane_identity
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

# --------------------------------------------------------------------------- #
# Grant 1: Network Contributor on the AKS node subnet.
#
# Required so the control plane can create and delete node NICs in a subnet it
# does not own. Scoped to the SUBNET, not the VNet and not the resource group -
# the cluster has no business reconfiguring the PostgreSQL delegated subnet.
# --------------------------------------------------------------------------- #

resource "azurerm_role_assignment" "aks_subnet_network_contributor" {
  scope                = azurerm_subnet.aks_nodes.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_control_plane.principal_id

  # The identity is brand new; Entra propagation can lag behind the ARM call.
  skip_service_principal_aad_check = true
}

# --------------------------------------------------------------------------- #
# Grant 2: Network Contributor on the static public IP.
#
# Required so the AKS cloud-controller-manager can attach our pre-created public
# IP to the Load Balancer it builds for the ingress-nginx Service.
#
# Scoped to the SINGLE PUBLIC IP RESOURCE rather than to the resource group.
# Granting Network Contributor on the whole RG - which most examples do - would
# also hand the cluster write access to the VNet, both subnets, and the
# PostgreSQL delegated subnet. Least privilege costs one extra line here.
# --------------------------------------------------------------------------- #

resource "azurerm_role_assignment" "aks_public_ip_network_contributor" {
  scope                = azurerm_public_ip.ingress.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_control_plane.principal_id

  skip_service_principal_aad_check = true
}
