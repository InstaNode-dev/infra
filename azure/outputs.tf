###############################################################################
# Outputs.
#
# These are the handoff surface between Phase 1 (this Terraform) and Phases 2-8
# (Kubernetes manifests, secrets, DNS). Anything an operator would otherwise
# have to hunt for in the portal belongs here.
#
# No secret is ever output. The PostgreSQL password is supplied by the operator
# and is deliberately not echoed back, not even as a sensitive output.
###############################################################################

# --------------------------------------------------------------------------- #
# Cluster access
# --------------------------------------------------------------------------- #

output "resource_group_name" {
  description = "Main resource group. Also the value for the azure-load-balancer-resource-group Service annotation."
  value       = azurerm_resource_group.main.name
}

output "aks_cluster_name" {
  description = "AKS cluster name."
  value       = azurerm_kubernetes_cluster.main.name
}

output "aks_node_resource_group" {
  description = "AKS-owned resource group holding the VMSS, Standard Load Balancer and node OS disks. Do not hand-edit."
  value       = azurerm_kubernetes_cluster.main.node_resource_group
}

output "get_credentials_command" {
  description = "Copy-paste command to configure kubectl against this cluster."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name} --overwrite-existing"
}

output "aks_oidc_issuer_url" {
  description = "OIDC issuer URL, needed to federate workload identities (e.g. for Key Vault) later."
  value       = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "aks_kubelet_identity_object_id" {
  description = "Object ID of the AKS-created kubelet identity. Needed if a registry pull role is ever granted (not required for GHCR, which uses an imagePullSecret)."
  value       = try(azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id, null)
}

output "network_policy_engine" {
  description = "Active NetworkPolicy engine. If this is ever empty, infra/k8s/data/networkpolicy.yaml enforces NOTHING."
  value       = azurerm_kubernetes_cluster.main.network_profile[0].network_policy
}

# --------------------------------------------------------------------------- #
# Ingress / DNS cutover (Phase 6 and Phase 8)
# --------------------------------------------------------------------------- #

output "ingress_public_ip" {
  description = "Static public IP. This is the address every Cloudflare A record points at in Phase 8 (api, pg, redis, mongo, s3, *.deployment - all DNS-only / grey cloud)."
  value       = azurerm_public_ip.ingress.ip_address
}

output "ingress_public_ip_name" {
  description = "Public IP resource name, for the azure-pip-name Service annotation."
  value       = azurerm_public_ip.ingress.name
}

output "ingress_public_ip_fqdn" {
  description = "Azure-provided hostname (<label>.eastus.cloudapp.azure.com) when public_ip_dns_label is set. Lets Phase 6-9 verification reach the ingress before the Cloudflare cutover."
  value       = azurerm_public_ip.ingress.fqdn
}

output "ingress_annotations" {
  description = <<-EOT
    Annotations the ingress-nginx controller Service MUST carry so AKS attaches
    the pre-created static IP instead of allocating a new one. Both are
    required: without the resource-group annotation AKS looks only in its own
    node resource group, does not find the IP, and the Service sits <pending>.
  EOT
  value = {
    "service.beta.kubernetes.io/azure-pip-name"                     = azurerm_public_ip.ingress.name
    "service.beta.kubernetes.io/azure-load-balancer-resource-group" = azurerm_resource_group.main.name
  }
}

# --------------------------------------------------------------------------- #
# PostgreSQL (Phase 3 secrets, Phase 5 migrations)
# --------------------------------------------------------------------------- #

output "postgres_server_name" {
  description = "PostgreSQL Flexible Server name."
  value       = azurerm_postgresql_flexible_server.main.name
}

output "postgres_fqdn" {
  description = "PostgreSQL FQDN. Resolvable ONLY from inside the VNet (private access) - it will not resolve from a laptop, and that is intended. See postgres.tf."
  value       = azurerm_postgresql_flexible_server.main.fqdn
}

output "postgres_database_names" {
  description = "Databases created on the server."
  value = {
    platform    = azurerm_postgresql_flexible_server_database.platform.name
    provisioner = azurerm_postgresql_flexible_server_database.provisioner.name
  }
}

output "postgres_connection_string_template" {
  description = <<-EOT
    DATABASE_URL / PROVISIONER_DATABASE_URL templates for the k8s Secret in
    Phase 3. Substitute the password you supplied as TF_VAR_postgres_admin_password.
    The password is intentionally NOT interpolated here so these values never
    reach the console or a CI log.
  EOT
  value = {
    DATABASE_URL             = "postgresql://${var.postgres_admin_username}:__PASSWORD__@${azurerm_postgresql_flexible_server.main.fqdn}:5432/${azurerm_postgresql_flexible_server_database.platform.name}?sslmode=require"
    PROVISIONER_DATABASE_URL = "postgresql://${var.postgres_admin_username}:__PASSWORD__@${azurerm_postgresql_flexible_server.main.fqdn}:5432/${azurerm_postgresql_flexible_server_database.provisioner.name}?sslmode=require"
  }
}

# --------------------------------------------------------------------------- #
# Networking
# --------------------------------------------------------------------------- #

output "vnet_name" {
  description = "Virtual network name."
  value       = azurerm_virtual_network.main.name
}

output "aks_subnet_id" {
  description = "AKS node subnet resource ID."
  value       = azurerm_subnet.aks_nodes.id
}

# --------------------------------------------------------------------------- #
# Cost
# --------------------------------------------------------------------------- #

output "monthly_cost_breakdown" {
  description = "Modelled monthly cost in USD at the CURRENT variable values, using verified East US retail prices (2026-08-09). See costs.tf."
  value = {
    terraform_managed = {
      aks_control_plane_free_tier = 0.00
      system_node_pool_compute    = local.cost_compute_system
      system_node_pool_os_disks   = local.cost_os_disk_system
      spot_node_pool_idle         = local.cost_compute_spot
      static_public_ip            = local.price_public_ip_per_month
      private_dns_zone            = local.price_private_dns_zone
      postgres_compute_b1ms       = local.price_pg_b1ms_compute
      postgres_storage            = local.cost_postgres_storage
      subtotal                    = local.monthly_cost_terraform_managed
    }
    not_managed_here = {
      terraform_state_storage      = local.price_tf_state_storage
      load_balancer_6_rules        = local.cost_load_balancer_low
      load_balancer_7_rules_w_nats = local.cost_load_balancer_high
      data_tier_pvcs               = local.price_pvc_data_tier_total
      cloudflare_r2                = 0.00
      ghcr_registry                = 0.00
    }
    total_low_estimate  = local.monthly_cost_total_low
    total_high_estimate = local.monthly_cost_total_high
    credit_months_low   = 1000 / local.monthly_cost_total_high
    credit_months_high  = 1000 / local.monthly_cost_total_low
  }
}
