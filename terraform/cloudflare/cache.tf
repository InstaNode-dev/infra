# Cache rules for api.staging.instanode.dev (and api.instanode.dev once
# Phase 4 flips proxied=true on the api A-record).
#
# D-12 (LOCKED): cache scope is an EXPLICIT path allowlist — `/healthz`,
# `/openapi.json`, `/llms.txt`. Everything else BYPASSES cache regardless
# of Authorization header presence. The original "bypass cache when
# Authorization header is set" approach was deleted because (a) the
# primitive doesn't exist on our zone tier, (b) it's a footgun if an
# authed response ever flows through cache.
#
# Plus: `instant_unexpected_cached_response_total` P0 metric in the api
# code (NOT here — handler-side) trips an alert if a request OUTSIDE
# the allowlist ever responds with cache-hit semantics. Defense in depth.

# Catch-all bypass at top priority — cache OFF for everything by default.
resource "cloudflare_ruleset" "api_cache_rules" {
  zone_id     = var.zone_id
  name        = "api-cache-rules"
  description = "D-12 explicit-path allowlist for api${var.environment == "production" ? "" : ".staging"}.${var.zone_name}"
  kind        = "zone"
  phase       = "http_request_cache_settings"

  # Rules evaluated top-to-bottom; first match wins.
  rules = [
    # Rule 1: bypass cache for everything by default (catch-all at lowest
    # priority via `Last`).
    {
      action      = "set_cache_settings"
      description = "bypass cache for all api.* paths by default"
      enabled     = true
      expression  = "(http.host eq \"api${var.environment == "production" ? "" : ".staging"}.${var.zone_name}\")"
      action_parameters = {
        cache = false
      }
    },
    # Rule 2: allow cache for /healthz (overrides bypass via earlier
    # evaluation only if listed BEFORE the catch-all; CF Rulesets evaluate
    # all rules and the LAST matching action wins for `set_cache_settings`,
    # so explicit allowlist comes after the catch-all).
    {
      action      = "set_cache_settings"
      description = "cache /healthz at edge for 30s — same SHA across instances"
      enabled     = true
      expression  = "(http.host eq \"api${var.environment == "production" ? "" : ".staging"}.${var.zone_name}\") and (http.request.uri.path eq \"/healthz\")"
      action_parameters = {
        cache = true
        edge_ttl = {
          mode    = "override_origin"
          default = 30
        }
        browser_ttl = {
          mode    = "override_origin"
          default = 0
        }
      }
    },
    # Rule 3: cache /openapi.json for 5 minutes — frequently re-fetched
    # by tooling, changes rarely.
    {
      action      = "set_cache_settings"
      description = "cache /openapi.json at edge for 5min"
      enabled     = true
      expression  = "(http.host eq \"api${var.environment == "production" ? "" : ".staging"}.${var.zone_name}\") and (http.request.uri.path eq \"/openapi.json\")"
      action_parameters = {
        cache = true
        edge_ttl = {
          mode    = "override_origin"
          default = 300
        }
        browser_ttl = {
          mode    = "override_origin"
          default = 60
        }
      }
    },
    # Rule 4: cache /llms.txt for 1 hour — static content from content
    # repo, refresh cadence is "operator manually re-syncs".
    {
      action      = "set_cache_settings"
      description = "cache /llms.txt at edge for 1h"
      enabled     = true
      expression  = "(http.host eq \"api${var.environment == "production" ? "" : ".staging"}.${var.zone_name}\") and (http.request.uri.path eq \"/llms.txt\")"
      action_parameters = {
        cache = true
        edge_ttl = {
          mode    = "override_origin"
          default = 3600
        }
        browser_ttl = {
          mode    = "override_origin"
          default = 600
        }
      }
    },
  ]
}
