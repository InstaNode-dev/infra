# Terraform alternative to ../apply.sh.
#
# Same JSON files in ../dashboards/ and ../alerts/ are applied to the
# New Relic account via the newrelic provider. Terraform tracks state
# (terraform.tfstate) so updates are idempotent without name-based lookups.
#
# Usage:
#   export NEW_RELIC_API_KEY=NRAK-...
#   export NEW_RELIC_ACCOUNT_ID=1234567
#   terraform init
#   terraform plan
#   terraform apply
#
# Notes:
#   - newrelic_one_dashboard_raw takes the raw NerdGraph JSON, so we feed
#     the same files apply.sh uses — only substituting accountIds:[0]
#     with the real account at apply time.
#   - newrelic_nrql_alert_condition takes structured fields (not raw JSON)
#     so we decode each alert JSON via jsondecode and map fields. This is
#     fragile — if the JSON shape ever drifts, the locals block needs to
#     change. Prefer apply.sh for that reason; this file is for shops that
#     already standardize on Terraform.

terraform {
  required_version = ">= 1.4"
  required_providers {
    newrelic = {
      source  = "newrelic/newrelic"
      version = "~> 3.40"
    }
  }
}

provider "newrelic" {
  # NEW_RELIC_API_KEY    — user key (NRAK-...)
  # NEW_RELIC_ACCOUNT_ID — numeric
  # NEW_RELIC_REGION     — "US" (default) or "EU"
}

variable "policy_name" {
  type    = string
  default = "instant-api alerts"
}

# -----------------------------------------------------------------------------
# Dashboards
# -----------------------------------------------------------------------------

locals {
  dashboard_files = fileset("${path.module}/../dashboards", "*.json")
  dashboards = {
    for f in local.dashboard_files :
    trimsuffix(f, ".json") => replace(
      file("${path.module}/../dashboards/${f}"),
      "\"accountIds\": [0]",
      "\"accountIds\": [${var.newrelic_account_id}]",
    )
  }
}

variable "newrelic_account_id" {
  type        = number
  description = "New Relic account ID. Reads from NEW_RELIC_ACCOUNT_ID env var if set."
}

resource "newrelic_one_dashboard_raw" "dashboards" {
  for_each   = local.dashboards
  account_id = var.newrelic_account_id

  # Name is parsed out of the JSON.
  name = jsondecode(each.value).name

  dynamic "page" {
    for_each = jsondecode(each.value).pages
    content {
      name        = page.value.name
      description = lookup(page.value, "description", null)

      dynamic "widget" {
        for_each = page.value.widgets
        content {
          title         = widget.value.title
          row           = widget.value.layout.row
          column        = widget.value.layout.column
          width         = widget.value.layout.width
          height        = widget.value.layout.height
          visualization = widget.value.visualization.id
          configuration = jsonencode(widget.value.rawConfiguration)
        }
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Alert policy + NRQL conditions
# -----------------------------------------------------------------------------

resource "newrelic_alert_policy" "instant" {
  name                = var.policy_name
  incident_preference = "PER_CONDITION"
}

locals {
  alert_files = fileset("${path.module}/../alerts", "*.json")
  alerts = {
    for f in local.alert_files :
    trimsuffix(f, ".json") => jsondecode(file("${path.module}/../alerts/${f}"))
  }
}

resource "newrelic_nrql_alert_condition" "conditions" {
  for_each = local.alerts

  policy_id = newrelic_alert_policy.instant.id
  name      = each.value.name
  enabled   = each.value.enabled
  type      = "static"
  # Description isn't a first-class field on this resource until provider
  # v3.45+; if you're on an older version, drop this line.
  description = lookup(each.value, "description", null)

  nrql {
    query = each.value.nrql.query
  }

  dynamic "critical" {
    for_each = [for t in each.value.terms : t if t.priority == "CRITICAL"]
    content {
      operator              = lower(critical.value.operator)
      threshold             = critical.value.threshold
      threshold_duration    = critical.value.thresholdDuration
      threshold_occurrences = lower(critical.value.thresholdOccurrences)
    }
  }

  dynamic "warning" {
    for_each = [for t in each.value.terms : t if t.priority == "WARNING"]
    content {
      operator              = lower(warning.value.operator)
      threshold             = warning.value.threshold
      threshold_duration    = warning.value.thresholdDuration
      threshold_occurrences = lower(warning.value.thresholdOccurrences)
    }
  }

  aggregation_window               = each.value.signal.aggregationWindow
  aggregation_method               = each.value.signal.aggregationMethod
  aggregation_delay                = each.value.signal.aggregationDelay
  fill_option                      = lower(each.value.signal.fillOption)
  fill_value                       = lookup(each.value.signal, "fillValue", null)
  expiration_duration              = each.value.expiration.expirationDuration
  open_violation_on_expiration     = each.value.expiration.openViolationOnExpiration
  close_violations_on_expiration   = each.value.expiration.closeViolationsOnExpiration
  violation_time_limit_seconds     = each.value.violationTimeLimitSeconds
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "dashboard_urls" {
  value = {
    for k, d in newrelic_one_dashboard_raw.dashboards :
    k => d.permalink
  }
}

output "alert_policy_id" {
  value = newrelic_alert_policy.instant.id
}

output "alert_condition_ids" {
  value = {
    for k, c in newrelic_nrql_alert_condition.conditions :
    k => c.id
  }
}
