###############################################################################
# Static public IP for the ingress-nginx LoadBalancer Service.
#
# COST: $3.65/mo
#   Standard IPv4 Static Public IP, $0.005/hour x 730 h
#   (East US, verified via prices.azure.com 2026-08-09).
#   Basic SKU would be $0.0036/h, but Basic public IPs are retired and cannot be
#   attached to a Standard Load Balancer, which is what AKS creates.
#
# --------------------------------------------------------------------------- #
# DECISION: created in the MAIN resource group, not the AKS node resource group.
# --------------------------------------------------------------------------- #
#
# Both placements work. The trade-off:
#
#   (a) In the AKS node resource group (rg-...-aks-nodes)
#       + No role assignment needed - the cluster identity already holds
#         Contributor there, so this file's grant in identity.tf disappears.
#       - The node resource group is OWNED BY AKS and is DELETED WITH THE
#         CLUSTER. Deleting or recreating the cluster destroys the IP.
#       - Microsoft explicitly documents the node resource group as
#         AKS-managed; hand-placed resources there are unsupported.
#
#   (b) In the main resource group + Network Contributor grant  <-- CHOSEN
#       + The IP outlives the cluster. This is the deciding factor: Cloudflare A
#         records for api / pg / redis / mongo / s3 / *.deployment all point at
#         this address (AZURE-MIGRATION-PLAN.md Phase 8). If a cluster rebuild
#         changed the IP, every rebuild would become a DNS migration with a
#         propagation window - on the exact records that carry customer database
#         connections.
#       + Terraform owns its full lifecycle; no resource is smuggled into a
#         resource group another system manages.
#       - Costs one role assignment, scoped to this resource only (identity.tf).
#
# The whole point of a *static* IP is that it is stable. Placing it inside a
# resource group whose lifetime is bound to the cluster gives up the property we
# are paying for.
#
# --------------------------------------------------------------------------- #
# HOW ingress-nginx CONSUMES THIS (Phase 6, not Terraform)
# --------------------------------------------------------------------------- #
# The Service must name BOTH the IP and its resource group, because the IP lives
# outside the node resource group where AKS looks by default:
#
#   apiVersion: v1
#   kind: Service
#   metadata:
#     name: ingress-nginx-controller
#     annotations:
#       service.beta.kubernetes.io/azure-pip-name: "<public_ip_name output>"
#       service.beta.kubernetes.io/azure-load-balancer-resource-group: "<resource_group_name output>"
#   spec:
#     type: LoadBalancer
#     loadBalancerIP: <ingress_public_ip output>   # legacy, keep for older charts
#
# `terraform output ingress_annotations` prints these already filled in.
#
# Omitting the resource-group annotation is the classic failure here: the
# Service sits in <pending> forever and the controller logs a "not found" for
# the public IP.
###############################################################################

resource "azurerm_public_ip" "ingress" {
  name                = local.public_ip_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  # Standard SKU is mandatory: AKS provisions a Standard Load Balancer, and
  # Standard LBs only accept Standard public IPs.
  sku      = "Standard"
  sku_tier = "Regional"

  # Static, not Dynamic. Dynamic Standard IPs do not exist, but stating it
  # explicitly documents the intent: this address is in DNS.
  allocation_method = "Static"
  ip_version        = "IPv4"

  # Optional <label>.eastus.cloudapp.azure.com hostname at no extra cost.
  # Lets Phase 6-9 verification hit the ingress over a real name before the
  # Cloudflare cutover in Phase 8.
  domain_name_label = var.public_ip_dns_label

  # No DDoS Protection Plan is provisioned (Azure DDoS Network Protection is
  # ~$2,944/mo). "VirtualNetworkInherited" means: inherit whatever the VNet has,
  # which is Azure's always-on free infrastructure-level DDoS protection.
  ddos_protection_mode = "VirtualNetworkInherited"

  tags = local.common_tags

  # HARDENING, deliberately NOT enabled yet:
  #
  #   lifecycle { prevent_destroy = true }
  #
  # This becomes correct the moment Phase 8 points Cloudflare A records at this
  # address - from then on, destroying it is a customer-visible DNS migration.
  # It is left off during Phase 1-9 because `prevent_destroy` cannot be driven
  # by a variable and would block the destroy-and-retry loop that a greenfield
  # build legitimately needs. See README.md "Hardening after Phase 9".
}
