###############################################################################
# Derived names and common tags.
#
# Naming follows the Cloud Adoption Framework abbreviation convention
# (rg-, aks-, vnet-, snet-, pip-, psql-, id-) so resources are self-describing
# in the portal and in cost exports.
###############################################################################

locals {
  # e.g. "instanode-prod-eastus"
  base_name = "${var.project}-${var.environment}-${var.location}"

  # Globally-unique names get the optional suffix; everything else does not.
  unique_suffix = var.name_suffix == "" ? "" : "-${var.name_suffix}"

  resource_group_name = "rg-${local.base_name}"

  # AKS creates node-level resources (VMSS, the Standard Load Balancer, node
  # OS disks) in a second, AKS-owned resource group. Naming it explicitly
  # instead of taking the default "MC_<rg>_<cluster>_<region>" keeps cost
  # exports readable and makes the "do not hand-edit this RG" boundary obvious.
  node_resource_group_name = "rg-${local.base_name}-aks-nodes"

  aks_cluster_name = "aks-${local.base_name}"
  aks_dns_prefix   = "${var.project}-${var.environment}"

  vnet_name              = "vnet-${local.base_name}"
  aks_subnet_name        = "snet-${var.project}-${var.environment}-aks"
  postgres_subnet_name   = "snet-${var.project}-${var.environment}-postgres"
  public_ip_name         = "pip-${local.base_name}-ingress"
  control_plane_identity = "id-${local.base_name}-aks"

  # PostgreSQL Flexible Server names are globally unique across all of Azure and
  # become the FQDN, so this is the one name likely to need name_suffix.
  postgres_server_name = "psql-${local.base_name}${local.unique_suffix}"

  # Private DNS zone for Flexible Server private access. Azure REQUIRES the zone
  # name to end in ".private.postgres.database.azure.com".
  postgres_private_dns_zone_name = "${var.project}-${var.environment}.private.postgres.database.azure.com"

  log_analytics_workspace_name = "log-${local.base_name}"

  common_tags = merge(
    {
      project     = var.project
      environment = var.environment
      managed_by  = "terraform"
      # Points a portal reader at the authoritative design doc rather than at
      # a guess about why any of this is shaped the way it is.
      source = "infra/azure"
      plan   = "docs/sessions/2026-08-09/AZURE-MIGRATION-PLAN.md"
    },
    var.tags,
  )
}
