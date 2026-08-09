###############################################################################
# Subscription cost budget + alerts.
#
# COST: $0.00/mo - Azure budgets and their alerts are free.
#
# WHY THIS EXISTS: the spending limit on subscription
# 73ae3d2a-5847-48f2-bcea-10bd3e1914f6 is OFF (measured 2026-08-09). There is no
# hard cutoff when the $1,000 Founders Hub credit is exhausted - spend simply
# continues against the payment instrument on file. A budget does not stop
# spend either, but it converts "found out at the next statement" into an email
# at 50% / 80% / 100%.
#
# --------------------------------------------------------------------------- #
# DEFAULT OFF - and this default is deliberate, not laziness.
# --------------------------------------------------------------------------- #
#
# The subscription's quotaId is `Sponsored_2016-01-01`, i.e. an Azure
# SPONSORSHIP subscription. Sponsorship subscriptions are known to have limited
# and inconsistent Azure Cost Management support: cost data is frequently
# unavailable through the standard Consumption APIs that budgets read, in which
# case Microsoft.Consumption/budgets either rejects creation or creates a budget
# that silently never evaluates - which is worse than no budget, because it
# looks like a working safety net.
#
# That could not be verified from here without applying it, and shipping an
# unverified resource into the first apply of a production restart would risk
# failing the apply for a non-essential guardrail.
#
# So it is written, syntax-checked and `terraform validate`-clean, but gated on
# var.enable_cost_budget (default false). It is left as a gated resource rather
# than as commented-out text specifically SO THAT it stays validated - commented
# Terraform rots silently and is never checked by anything.
#
# TO ENABLE, once someone confirms Cost Management works on this subscription:
#   1. Check the portal shows real cost data:
#        az consumption budget list --subscription <id>
#      or Cost Management + Billing -> Cost analysis. If cost analysis shows
#      data, budgets will work.
#   2. Set in terraform.tfvars:
#        enable_cost_budget   = true
#        budget_alert_emails  = ["you@example.com"]
#   3. terraform apply, then confirm the budget appears under
#      Cost Management -> Budgets.
#   If step 3 fails, set enable_cost_budget back to false and rely on the
#   monthly manual check in README.md instead.
###############################################################################

resource "azurerm_consumption_budget_subscription" "main" {
  count = var.enable_cost_budget ? 1 : 0

  name            = "budget-${local.base_name}"
  subscription_id = "/subscriptions/${var.subscription_id}"

  amount     = var.monthly_budget_amount
  time_grain = "Monthly"

  time_period {
    # Azure requires the start date to be the FIRST DAY OF A MONTH, in RFC3339,
    # and it must not be more than three months in the past.
    start_date = var.budget_start_date
  }

  # 50% - "you are on track, or you are not".
  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.budget_alert_emails
  }

  # 80% - time to act while there is still headroom in the month.
  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.budget_alert_emails
  }

  # 100% actual - the month's budget is gone.
  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.budget_alert_emails
  }

  # 100% forecast - fires EARLY, based on Azure's projection of month-end spend.
  # This is the one that catches a runaway resource (a node pool that scaled and
  # never scaled back, Container Insights left on) days before the actual
  # threshold would.
  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = var.budget_alert_emails
  }
}
