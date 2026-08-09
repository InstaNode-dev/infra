###############################################################################
# Provider configuration.
#
# Authentication is NEVER configured in code. The provider picks up credentials
# from the environment, in this order of preference for this project:
#   1. `az login` (Azure CLI auth)      - operator running apply from a laptop
#   2. ARM_* environment variables      - CI, if apply is ever automated
#
# `subscription_id` is required by azurerm >= 4.0. Supply it via
# `ARM_SUBSCRIPTION_ID` or terraform.tfvars - see terraform.tfvars.example.
###############################################################################

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    resource_group {
      # Refuse to delete a resource group that still contains resources.
      # Guards against a `terraform destroy` on the wrong workspace silently
      # taking the cluster and the platform database with it.
      prevent_deletion_if_contains_resources = true
    }

    postgresql_flexible_server {
      # Some PostgreSQL server parameters are "static" and only take effect
      # after a restart. Let the provider restart the server when such a
      # parameter changes, so applied config and running config cannot silently
      # diverge. This means an apply that touches a static parameter causes a
      # brief database restart - expect it, and schedule those applies.
      restart_server_on_configuration_value_change = true
    }
  }
}
