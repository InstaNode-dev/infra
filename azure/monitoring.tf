###############################################################################
# Log Analytics workspace for Container Insights.
#
# COST WHEN ENABLED (East US, verified prices.azure.com 2026-08-09):
#   Analytics Logs data ingestion        $2.30/GB
#   Retention beyond the free 31 days    $0.10/GB/mo
#
#   Container Insights on a small AKS cluster typically ingests 1-3 GB/day:
#       1 GB/day  ->  ~30 GB/mo  ->   ~$69/mo
#       3 GB/day  ->  ~90 GB/mo  ->  ~$207/mo
#   That is 70%-200% of the entire monthly platform budget, spent on logs.
#
# COST WHEN DISABLED (the default): $0.00/mo. count = 0 means the workspace is
# not created at all, so there is no idle charge.
#
# WHY OFF: the platform already ships metrics and logs to New Relic via
# infra/k8s/newrelic-prometheus-agent.yaml. Container Insights would duplicate
# that telemetry at Azure retail prices. Out of scope per the migration brief.
#
# IF IT IS EVER TURNED ON: daily_quota_gb is set from
# var.log_analytics_daily_quota_gb (default 1 GB/day, a ~$69/mo ceiling). The
# quota causes ingestion to STOP for the rest of the UTC day once hit - data is
# dropped, not queued. That is the intended behaviour here: a hard cost ceiling
# is worth more than complete logs on a subscription with no spending limit.
###############################################################################

resource "azurerm_log_analytics_workspace" "main" {
  count = var.enable_container_insights ? 1 : 0

  name                = local.log_analytics_workspace_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  # PerGB2018 is the current pay-as-you-go SKU. Commitment tiers start at
  # 100 GB/day and are irrelevant at this scale.
  sku = "PerGB2018"

  retention_in_days = var.log_analytics_retention_days
  daily_quota_gb    = var.log_analytics_daily_quota_gb

  tags = local.common_tags
}
