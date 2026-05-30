# DNS records under management.
#
# Pre-cutover ritual (D-3): TTL must be 60s for ≥48h BEFORE any cut.
# Setting it that low here means terraform plan/apply itself satisfies
# the pre-step the first time we touch the record.
#
# `proxied = true` = CF orange-cloud; `false` = grey-cloud (DNS only, no
# proxy). Today: marketing apex is orange (Phase 0 baseline), api is grey
# (becomes orange in Phase 4 — flip this flag in that phase's PR).

locals {
  marketing_origin = "instanode-web.pages.dev" # set per environment in staging.tfvars / production.tfvars after Pages project is created
  api_origin       = "152.42.154.144"          # DigitalOcean LB; replaced with LB pool resource in Phase 4
}

resource "cloudflare_dns_record" "apex" {
  zone_id = var.zone_id
  name    = var.zone_name
  type    = "CNAME"
  content = local.marketing_origin
  ttl     = 60
  proxied = true
  comment = "marketing apex; CNAME-flattened to Pages project"
}

resource "cloudflare_dns_record" "www" {
  zone_id = var.zone_id
  name    = "www.${var.zone_name}"
  type    = "CNAME"
  content = var.zone_name
  ttl     = 60
  proxied = true
  comment = "www → apex redirect handled by CF page rule"
}

resource "cloudflare_dns_record" "api" {
  zone_id = var.zone_id
  name    = "api.${var.zone_name}"
  type    = "A"
  content = local.api_origin
  ttl     = 60
  proxied = false # Phase 4 flips this to true after CF orange-cloud cache rules are applied
  comment = "api; grey-cloud today, orange-cloud per Phase 4 cut (D-3)"
}

resource "cloudflare_dns_record" "staging" {
  count   = var.environment == "staging" ? 1 : 0
  zone_id = var.zone_id
  name    = "staging.${var.zone_name}"
  type    = "CNAME"
  content = "instant-staging.${var.zone_name}.cdn.cloudflare.net" # Pages preview hostname; replaced after Pages project is up
  ttl     = 60
  proxied = true
  comment = "staging mirror per D-2"
}
