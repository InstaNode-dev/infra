###############################################################################
# Terraform + provider pinning, and the remote state backend.
#
# PROVIDER PIN — hashicorp/azurerm ~> 5.0
#   5.0.1 is the current GA major (verified against registry.terraform.io on
#   2026-08-09). We deliberately do NOT start a brand-new permanent production
#   estate on the outgoing 4.x line, because that guarantees a forced provider
#   migration within months.
#
#   Risk check performed, not assumed: the provider schemas for every resource
#   this configuration uses were diffed between 4.81.0 and 5.0.1. The deltas are:
#     azurerm_kubernetes_cluster            - kubelet_config.container_log_max_line
#                                           - linux_os_config.transparent_huge_page_enabled
#     azurerm_kubernetes_cluster_node_pool  (same two, nested)
#     azurerm_subnet                         service_endpoints -> service_endpoint block
#     provider block                        - enhanced_validation, skip_provider_registration
#     azurerm_postgresql_flexible_server     no change
#     azurerm_public_ip                      no change
#   None of those are used here, so 4.81.0 is a verified drop-in fallback if the
#   5.x line ever misbehaves: change the constraint to "~> 4.81" and re-init.
#
# STATE BACKEND — Azure Storage, not local. See ./README.md "State backend".
#   Terraform state for this configuration contains the PostgreSQL admin
#   password in PLAINTEXT. `sensitive = true` only redacts CLI output; it does
#   not encrypt state. Local state would put a production database credential in
#   an unencrypted, unversioned, unlocked file on one laptop.
#
#   This is a PARTIAL backend configuration on purpose - no account names or
#   keys are committed. Initialise with:
#       terraform init -backend-config=backend.hcl
#   Create the storage account first with ./bootstrap (see bootstrap/README.md);
#   that resolves the chicken-and-egg, and the bootstrap state contains no
#   secrets at all, so bootstrap can safely use local state.
#
#   To validate/plan-check without any backend at all:
#       terraform init -backend=false && terraform validate
###############################################################################

terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
  }

  backend "azurerm" {}
}
