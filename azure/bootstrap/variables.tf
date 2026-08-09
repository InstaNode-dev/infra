variable "subscription_id" {
  description = "Azure subscription ID. Prefer supplying via ARM_SUBSCRIPTION_ID."
  type        = string
}

variable "project" {
  description = "Project slug, used in resource names."
  type        = string
  default     = "instanode"
}

variable "location" {
  description = "Region for the state storage account. Same region as the platform keeps latency and any future private-endpoint work simple."
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = <<-EOT
    Resource group for the state backend. Deliberately SEPARATE from the
    platform resource group: a `terraform destroy` of the platform must never be
    able to take the state that describes it.
  EOT
  type        = string
  default     = "rg-instanode-tfstate"
}

variable "storage_account_name" {
  description = <<-EOT
    Storage account name. Leave null to generate st<project>tfstate<random6>.
    Must be globally unique across all of Azure, 3-24 chars, lowercase
    alphanumeric only.
  EOT
  type        = string
  default     = null
}

variable "container_name" {
  description = "Blob container holding state files. One container can hold several state keys (e.g. prod.tfstate, staging.tfstate)."
  type        = string
  default     = "tfstate"
}
