variable "account_id" {
  type        = string
  description = "Cloudflare account ID (CF for Startups credit-tagged account)."
  default     = "613a9e74136364c781a8e258326019f9"
}

variable "zone_id" {
  type        = string
  description = "Cloudflare zone ID for instanode.dev."
  default     = "08a1a569d2d6f9a713dc6d62103c5dc6"
}

variable "zone_name" {
  type    = string
  default = "instanode.dev"
}

variable "environment" {
  type        = string
  description = "staging or production. Selected via `terraform workspace`."
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be one of: staging, production."
  }
}

variable "deploy_token_expires_on" {
  type        = string
  description = "RFC3339 expiry for the deploy token. Rotate every ≤180d."
  default     = "2026-11-26T23:59:59Z"
}

variable "admin_tunnel_token_expires_on" {
  type        = string
  description = "RFC3339 expiry for the admin/tunnel token. Rotate every ≤90d."
  default     = "2026-08-28T23:59:59Z"
}
