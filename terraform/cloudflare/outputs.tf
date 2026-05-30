# Token VALUES are sensitive — operator must `terraform output -raw deploy_token`
# and immediately pipe into `kubectl create secret` / `gh secret set`. Never
# `terraform output` (no -raw) in a CI log: the redacted form ("(sensitive)")
# is still a footgun if anyone removes `sensitive = true`.

output "deploy_token_id" {
  value       = cloudflare_account_token.deploy.id
  description = "Token A id (non-sensitive; safe in CI logs)."
}

output "deploy_token" {
  value       = cloudflare_account_token.deploy.value
  description = "Token A secret. Pipe directly into k8s/GH secret; never log."
  sensitive   = true
}

output "admin_tunnel_token_id" {
  value       = cloudflare_account_token.admin_tunnel.id
  description = "Token B id (non-sensitive)."
}

output "admin_tunnel_token" {
  value       = cloudflare_account_token.admin_tunnel.value
  description = "Token B secret. Operator-only; never put into CI."
  sensitive   = true
}

output "account_id" {
  value = var.account_id
}

output "zone_id" {
  value = var.zone_id
}
