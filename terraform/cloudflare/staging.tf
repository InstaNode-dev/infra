# Staging-environment subdomains under staging.instanode.dev.
#
# All resources here are count-gated on `var.environment == "staging"` so
# they only materialize in the staging workspace; the production workspace
# plan shows no changes from this file.
#
# DIVISION OF RESPONSIBILITY between TF and wrangler:
#
#  - **TF owns** wildcard records, env-level subdomains (dashboard, webhook),
#    and the deployment-app wildcard. These don't have a 1:1 Worker/Container
#    mapping or they're pre-deploy plumbing.
#  - **Wrangler owns** service-specific hostnames via `custom_domain = true`
#    in each wrangler.toml. wrangler auto-creates the DNS + cert + route on
#    first deploy. That covers: api.staging.instanode.dev (managed by
#    infra/wrangler/api/wrangler.toml).
#
# DO NOT add explicit TF records for hostnames wrangler is already
# custom-domain-claiming — wrangler will fail to deploy with "DNS record
# already exists" if both manage it.

locals {
  is_staging = var.environment == "staging"
  # All staging subdomains live under this stem.
  staging_stem = "staging.${var.zone_name}"
}

# -----------------------------------------------------------------------------
# Wildcards under *.staging.instanode.dev
# -----------------------------------------------------------------------------
#
# Each per-tenant service in wrangler/ uses a hostname-shard pattern:
#   - pg-customer-<tenant>.staging.instanode.dev  (pg-customers Container)
#   - mongo-<tenant>.staging.instanode.dev        (mongodb Container)
#   - redis-<tenant>.staging.instanode.dev        (redis-provision Container)
#   - nats-<tenant>.staging.instanode.dev         (nats Container)
#
# A single proxied wildcard CNAME catches all of them; the Worker shells
# in each wrangler service extract the tenant from the hostname and
# dispatch to the right Durable Object via `idFromName(tenant)`.

resource "cloudflare_dns_record" "staging_wildcard" {
  count   = local.is_staging ? 1 : 0
  zone_id = var.zone_id
  name    = "*.${local.staging_stem}"
  type    = "CNAME"
  # CF requires SOME content for proxied CNAMEs; this is a placeholder. The
  # cloudflare_workers_route below routes traffic to the correct Worker
  # regardless of what's here. A 404 sink is intentional — any unrouted
  # subdomain hits CF's default 404 page.
  content = local.staging_stem
  ttl     = 1
  proxied = true
  comment = "wildcard for per-tenant CF Container services in staging; routed via cloudflare_workers_route below"
}

# -----------------------------------------------------------------------------
# Deployment-app wildcard: *.deployment.staging.instanode.dev
# -----------------------------------------------------------------------------
#
# Mirror of prod's `*.deployment.instanode.dev`. Every /deploy/new staging
# call provisions an app at `<slug>.deployment.staging.instanode.dev`.
# Wrangler-managed Containers for the deploy compute target this wildcard;
# the api Worker creates a DNS-less custom-domain claim per slug, but the
# wildcard ensures any future deploy slug resolves to CF before its
# custom-domain claim lands.

resource "cloudflare_dns_record" "staging_deployment_wildcard" {
  count   = local.is_staging ? 1 : 0
  zone_id = var.zone_id
  name    = "*.deployment.${local.staging_stem}"
  type    = "CNAME"
  content = "deployment.${local.staging_stem}"
  ttl     = 1
  proxied = true
  comment = "wildcard for /deploy/new staging apps (mirrors prod *.deployment.instanode.dev)"
}

# Anchor for the deployment wildcard CNAME (the wildcard's content needs
# a real record at the parent name).
resource "cloudflare_dns_record" "staging_deployment_anchor" {
  count   = local.is_staging ? 1 : 0
  zone_id = var.zone_id
  name    = "deployment.${local.staging_stem}"
  type    = "AAAA"
  content = "100::" # IPv6 discard prefix — never reachable; CF proxied front-end terminates
  ttl     = 1
  proxied = true
  comment = "anchor for deployment wildcard CNAME (CF requires a real record at the parent)"
}

# -----------------------------------------------------------------------------
# Webhook subdomain: webhook.staging.instanode.dev
# -----------------------------------------------------------------------------
#
# /webhook/new staging endpoints return a URL at this host. Routed to the
# api Container via a Worker route. Separate subdomain (vs api.staging.)
# so customers can filter outbound webhook traffic by destination host.

resource "cloudflare_dns_record" "staging_webhook" {
  count   = local.is_staging ? 1 : 0
  zone_id = var.zone_id
  name    = "webhook.${local.staging_stem}"
  type    = "AAAA"
  content = "100::" # placeholder; CF orange-cloud handles routing
  ttl     = 1
  proxied = true
  comment = "staging /webhook/new receiver subdomain"
}

# -----------------------------------------------------------------------------
# Dashboard subdomain: dashboard.staging.instanode.dev
# -----------------------------------------------------------------------------
#
# CEO killed dashboard-on-Pages for PROD (D-5) but staging dashboard is
# useful for QA. Points at the same dashboard Pages project at the
# `staging` branch preview hostname. NOT enabled for production — D-5
# stands.

resource "cloudflare_dns_record" "staging_dashboard" {
  count   = local.is_staging ? 1 : 0
  zone_id = var.zone_id
  name    = "dashboard.${local.staging_stem}"
  type    = "CNAME"
  content = "instanode-dashboard-staging.pages.dev" # set after dashboard Pages project is created
  ttl     = 1
  proxied = true
  comment = "staging dashboard — QA-only; D-5 keeps prod dashboard off Pages"
}

# -----------------------------------------------------------------------------
# Workers Routes for per-tenant wildcards
# -----------------------------------------------------------------------------
#
# `custom_domain = true` in wrangler.toml does NOT support wildcards.
# Wildcards need cloudflare_workers_route + a wildcard DNS record (done
# above). Each route binds a pattern to a specific Worker name; wrangler
# deploys the Worker, TF wires the route.

resource "cloudflare_workers_route" "staging_pg_customers" {
  count   = local.is_staging ? 1 : 0
  zone_id = var.zone_id
  pattern = "pg-customer-*.${local.staging_stem}/*"
  script  = "instanode-pg-customers-staging"
}

resource "cloudflare_workers_route" "staging_mongodb" {
  count   = local.is_staging ? 1 : 0
  zone_id = var.zone_id
  pattern = "mongo-*.${local.staging_stem}/*"
  script  = "instanode-mongodb-staging"
}

resource "cloudflare_workers_route" "staging_redis" {
  count   = local.is_staging ? 1 : 0
  zone_id = var.zone_id
  pattern = "redis-*.${local.staging_stem}/*"
  script  = "instanode-redis-provision-staging"
}

resource "cloudflare_workers_route" "staging_nats" {
  count   = local.is_staging ? 1 : 0
  zone_id = var.zone_id
  pattern = "nats-*.${local.staging_stem}/*"
  script  = "instanode-nats-staging"
}

# -----------------------------------------------------------------------------
# Pages custom domain — staging marketing site
# -----------------------------------------------------------------------------
#
# The Pages project itself is declared in pages.tf with the
# `var.environment == "staging" ? "instanode-web-staging" : "instanode-web"`
# name pattern. The custom-domain attachment is here so prod's pages.tf
# stays simple.

resource "cloudflare_pages_domain" "staging_marketing" {
  count        = local.is_staging ? 1 : 0
  account_id   = var.account_id
  project_name = "instanode-web-staging"
  name         = local.staging_stem
  depends_on   = [cloudflare_dns_record.staging]
}
