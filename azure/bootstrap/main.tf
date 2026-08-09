###############################################################################
# Terraform remote-state backend bootstrap.
#
# THE CHICKEN AND EGG, AND HOW THIS RESOLVES IT
#
#   The root configuration (../) stores its state in Azure Storage, because that
#   state contains the PostgreSQL admin password in plaintext. But the storage
#   account has to exist before Terraform can use it as a backend.
#
#   This directory creates that storage account, and uses LOCAL STATE to do it.
#   That is safe, and it is safe for a specific reason rather than by
#   convention: THIS configuration creates no secrets. A resource group, a
#   storage account, and a blob container - no passwords, no keys, no
#   connection strings in state. The local state file here is not sensitive.
#
#   Run this ONCE, then never again. The root configuration is where all
#   ongoing work happens.
#
# COST: $0.01/mo.
#   Hot LRS block blob storage is $0.0208/GB/month (East US, verified via
#   prices.azure.com 2026-08-09). Terraform state for the root configuration is
#   well under 1 MB even with every version retained. Transactions cost
#   fractions of a cent per apply. The migration brief estimated ~$1/mo; the
#   measured price is effectively zero.
#
# WHY NOT JUST USE LOCAL STATE FOR EVERYTHING?
#
#   Because the root state holds a production database credential. Local state
#   means that credential sits in an unencrypted file, with no versioning, no
#   locking, and no backup, on one laptop. `sensitive = true` does not change
#   that - it only redacts CLI output.
#
#   The storage account below gives, for one cent a month:
#     * encryption at rest (default, Microsoft-managed keys)
#     * blob versioning + 30-day soft delete - recovery from a corrupted or
#       accidentally-deleted state file, which is otherwise unrecoverable
#     * native blob leases for state locking - two concurrent applies cannot
#       race (Terraform 1.x uses blob leases; no DynamoDB-equivalent needed)
#     * Entra RBAC instead of shared keys - see use_azuread_auth in backend.hcl
#     * TLS 1.2 minimum, no public blob access
###############################################################################

resource "azurerm_resource_group" "tfstate" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    project    = var.project
    managed_by = "terraform"
    purpose    = "terraform-remote-state"
  }
}

# Storage account names are globally unique across all of Azure, 3-24
# characters, lowercase alphanumeric only. A random suffix avoids a collision
# on a predictable name like "stinstanodetfstate".
resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_storage_account" "tfstate" {
  name                = coalesce(var.storage_account_name, "st${var.project}tfstate${random_string.suffix.result}")
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location

  account_tier             = "Standard"
  account_replication_type = "LRS" # state is reproducible from code; GRS is not worth 2x
  account_kind             = "StorageV2"
  access_tier              = "Hot"

  # No anonymous access to state, ever.
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = true # operator applies from a laptop; see note below

  min_tls_version = "TLS1_2"

  # Prefer Entra RBAC over shared account keys. The backend uses
  # use_azuread_auth = true, so no storage key is ever written to a config file
  # or a CI secret.
  shared_access_key_enabled = true # keep true: some tooling still falls back to keys

  blob_properties {
    # THE POINT OF THIS ACCOUNT. A corrupted or truncated state file is
    # otherwise unrecoverable and means importing every resource by hand.
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  tags = {
    project    = var.project
    managed_by = "terraform"
    purpose    = "terraform-remote-state"
  }

  # NOTE on public_network_access_enabled: restricting this to a fixed operator
  # IP or a private endpoint is stronger, but it locks out laptop applies from
  # any other network and blocks CI. Data-plane access still requires an Entra
  # identity holding "Storage Blob Data Contributor" - the account being
  # network-reachable does not make its contents readable. Tighten it if apply
  # ever moves to a fixed egress.
}

resource "azurerm_storage_container" "tfstate" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}
