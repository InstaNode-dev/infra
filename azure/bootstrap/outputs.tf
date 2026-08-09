output "resource_group_name" {
  description = "State backend resource group."
  value       = azurerm_resource_group.tfstate.name
}

output "storage_account_name" {
  description = "State backend storage account."
  value       = azurerm_storage_account.tfstate.name
}

output "container_name" {
  description = "State backend blob container."
  value       = azurerm_storage_container.tfstate.name
}

output "backend_hcl" {
  description = <<-EOT
    Ready-to-use contents for ../backend.hcl. Write it with:
      terraform output -raw backend_hcl > ../backend.hcl
    then, from ../:
      terraform init -backend-config=backend.hcl
  EOT
  value       = <<-EOT
    resource_group_name  = "${azurerm_resource_group.tfstate.name}"
    storage_account_name = "${azurerm_storage_account.tfstate.name}"
    container_name       = "${azurerm_storage_container.tfstate.name}"
    key                  = "instanode-prod.tfstate"
    use_azuread_auth     = true
  EOT
}

output "grant_state_access_command" {
  description = "Grant an operator data-plane access to state. Entra RBAC, not shared keys - required because the backend sets use_azuread_auth = true."
  value       = "az role assignment create --role 'Storage Blob Data Contributor' --assignee <user-or-sp-object-id> --scope ${azurerm_storage_account.tfstate.id}"
}
