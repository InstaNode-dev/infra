###############################################################################
# Bootstrap uses LOCAL STATE deliberately - see main.tf for why that is safe
# here (this configuration creates no secrets).
#
# NOTE on the provider pin: this directory REQUIRES azurerm 5.x.
# `azurerm_storage_container` took `storage_account_name` in 4.x and takes
# `storage_account_id` in 5.x. Unlike the root configuration, this one is not a
# drop-in against 4.81.
###############################################################################

terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {}
}
