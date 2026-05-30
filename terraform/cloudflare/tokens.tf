# Two scoped API tokens replace the Global API Key for CI / DevOps use.
# Source: exported from CF dashboard 2026-05-30, renamed to avoid the
# default `example_account_token` collision.
#
# WARNING — token values are SENSITIVE outputs. They appear once in TF
# state after `apply`. Operator MUST run the `make install-secrets`
# helper (see Makefile) to push them into k8s + GH org secrets, then
# rotate state.

# Token A — day-to-day deploy + DNS + R2 + Pages + Workers + Page Rules
# + Load Balancing + Cache Purge + Zone Settings. Account-broad, zone-
# narrow on instanode.dev. Used by CI.
resource "cloudflare_account_token" "deploy" {
  account_id = var.account_id
  name       = "instanode-migration-deploy-${var.environment}"
  expires_on = var.deploy_token_expires_on

  policies = [
    # Zone-scoped permissions on instanode.dev (zone_id pinned).
    {
      effect = "allow"
      permission_groups = [
        { id = "c4df38be41c247b3b4b7702e76eadae0" }, # Zone:Read
        { id = "3030687196b94b638145a3953da2b699" }, # DNS:Edit
        { id = "c8fed203ed3043cba015a93ad1616f1f" }, # Zone Settings:Edit
        { id = "c03055bc037c4ea9afb9a9f104b7b721" }, # Cache Purge:Purge
        { id = "e17beae8b8cb423a99b1730f21238bed" }, # Page Rules:Edit
        { id = "ed07f6c337da4195b4e72a1fb2c6bcae" }, # SSL and Certificates:Edit
        { id = "6d7f2f5f5b1d4a0e9081fdc98d432fd1" }, # Load Balancers:Edit
        { id = "4755a26eedb94da69e1066d98aa820be" }, # Apps:Edit (zone-side)
      ]
      resources = jsonencode({
        "com.cloudflare.api.account.zone.${var.zone_id}" = "*"
      })
    },
    # Account-scoped permissions for resources that aren't zone-bound.
    {
      effect = "allow"
      permission_groups = [
        { id = "dc44f27f48ab405392a5f69fe822bd01" }, # Workers Scripts:Edit
        { id = "8d28297797f24fb8a0c332fe0866ec89" }, # Workers KV Storage:Edit
        { id = "bf7481a1826f439697cb59a20b22293e" }, # Workers R2 Storage:Edit
        { id = "f7f0eda5697f475c90846e879bab8666" }, # Cloudflare Pages:Edit
        { id = "e086da7e2179491d91ee5f35b3ca210a" }, # Account Settings:Read
        { id = "d2a1802cc9a34e30852f8b33869b2f3c" }, # LB Monitors & Pools:Edit
        { id = "c1fde68c7bcc44588cbb6ddbc16d6480" }, # Account Analytics:Read
      ]
      resources = jsonencode({
        "com.cloudflare.api.account.${var.account_id}" = "*"
      })
    },
  ]
}

# Token B — break-glass / rare-use Tunnel + Access. Smaller scope, shorter
# expiry. NOT used by CI; kept as separate apply for blast-radius isolation.
resource "cloudflare_account_token" "admin_tunnel" {
  account_id = var.account_id
  name       = "instanode-migration-admin-tunnel-${var.environment}"
  expires_on = var.admin_tunnel_token_expires_on

  policies = [{
    effect = "allow"
    permission_groups = [
      { id = "ad7a6f88896d498f98eb30592abfbbf4" }, # Cloudflare Tunnel:Edit
      { id = "77efc2c0724d4c4eb94bfd9656247130" }, # Access: Apps and Policies:Edit
      { id = "db37e5f1cb1a4e1aabaef8deaea43575" }, # Access: Service Tokens:Edit
      { id = "a1c0fec57cf94af79479a6d827fa518c" }, # Access: Organizations, Identity Providers:Edit
      { id = "1e13c5124ca64b72b1969a67e8829049" }, # Account Settings:Read
    ]
    resources = jsonencode({
      "com.cloudflare.api.account.${var.account_id}" = "*"
    })
  }]
}
