###############################################################################
# COST MODEL
#
# Every figure below is a REAL East US retail price pulled from the public Azure
# Retail Prices API (https://prices.azure.com/api/retail/prices, no auth) on
# 2026-08-09, or a documented $0. Nothing here is a guess; anything uncertain is
# labelled as a range with its assumption stated.
#
# It is expressed as Terraform locals rather than as a comment so that
# `terraform output monthly_cost_breakdown` reports the cost of the CURRENT
# variable values - if someone raises system_node_max_count or turns on
# Container Insights, the number moves with them.
#
# ============================================================================ #
# A. STEADY STATE - what this Terraform creates and bills every month
# ============================================================================ #
#
#   Resource group                                        $0.00
#   Virtual network + 2 subnets                           $0.00
#   Private DNS zone (PostgreSQL private access)          $0.50
#   Private DNS zone VNet link                            $0.00
#   Private DNS queries (<1M/mo @ $0.40/M)                $0.00
#   User-assigned managed identity + 2 role assignments   $0.00
#   AKS control plane (Free tier)                         $0.00
#   System pool: 1 x Standard_B2as_v2                    $54.90
#   System pool OS disk: 64 GiB managed (P6)             $10.21
#   Spot build pool: min_count = 0, idle                  $0.00
#   Static public IP (Standard, static IPv4)              $3.65
#   PostgreSQL Flexible Server B1ms compute              $12.41
#   PostgreSQL storage 32 GiB @ $0.115/GiB                $3.68
#   PostgreSQL backup, 7-day PITR (within free)           $0.00
#   Log Analytics (disabled)                              $0.00
#   Cost budget (disabled; free anyway)                   $0.00
#   ------------------------------------------------------------
#   TERRAFORM-MANAGED SUBTOTAL                           $85.35/mo
#
#   Terraform state storage account (./bootstrap)         $0.01/mo
#     Hot LRS block blob @ $0.0208/GB/mo; state is well under 1 MB even with
#     versioning. The brief estimated ~$1/mo; the measured price makes it
#     effectively free. Transactions are fractions of a cent per apply.
#
# ============================================================================ #
# B. NOT CREATED BY THIS TERRAFORM - later phases, still on the bill
# ============================================================================ #
#
#   Standard Load Balancer                       $18.25 - $32.85/mo
#   PVCs: 2 x E4 (32 GiB) + 2 x E2 (8 GiB)                $6.00/mo
#   Egress (first 100 GB/mo free)                         $0.00/mo
#   Cloudflare R2 object storage (10 GB free)             $0.00/mo
#   GHCR container registry                               $0.00/mo
#   ------------------------------------------------------------
#   LATER-PHASE SUBTOTAL                         $24.25 - $38.85/mo
#
#   The Load Balancer is created BY AKS, in the AKS-owned node resource group,
#   at Phase 6 when the ingress-nginx Service of type LoadBalancer is applied.
#   It is not a Terraform resource here, but it is unavoidable and it is the
#   single largest correction to the migration plan's cost model:
#
#     Standard LB, first 5 rules (LB rules + OUTBOUND rules)  $0.025/h = $18.25/mo
#     each additional rule                                    $0.010/h =  $7.30/mo
#     data processed                                          $0.005/GB
#     (verified: serviceName "Load Balancer", armRegionName "Global")
#
#   Rule count for this platform. Every L4 service is funnelled through the
#   ingress-nginx tcp-services ConfigMap onto ONE LoadBalancer Service (verified
#   by reading infra/k8s: there is no other type: LoadBalancer Service in the
#   repo), and EACH FRONTEND PORT IS ONE LB RULE:
#
#     80/tcp    HTTP  ingress            1
#     443/tcp   HTTPS ingress            1
#     5432/tcp  pg.instanode.dev         1
#     6379/tcp  redis.instanode.dev      1
#     27017/tcp mongo.instanode.dev      1
#     4222/tcp  nats  (see note)         0 or 1
#     AKS outbound SNAT rule             1
#     -----------------------------------------
#     total                              6 or 7 rules
#
#   With 5 included, that is 1-2 overage rules: $25.55/mo or $32.85/mo.
#   The NATS row is uncertain: CLAUDE.md states NATS is ClusterIP-only in prod,
#   while infra/k8s/data/nats.yaml:240 says the LB exposes 4222 via tcp-services.
#   Resolve it in Phase 6; not exposing 4222 publicly saves $7.30/mo.
#
#   AZURE-MIGRATION-PLAN.md section 4 budgets $18.25/mo for the LB on the
#   assumption of "<=5 rules". The topology does not fit in 5. See README.md
#   "Corrections to the migration plan".
#
# ============================================================================ #
# C. TOTAL
# ============================================================================ #
#
#   A + B  =  $109.61/mo  (6 LB rules, NATS not public)
#          =  $124.21/mo  (7 LB rules, NATS public)
#
#   AZURE-MIGRATION-PLAN.md section 4 models $98.90/mo. The gap is two real
#   omissions in that model, not new scope:
#     + $10.21  AKS node OS disk - the plan has no line for it at all, and it
#               cannot be avoided: ephemeral OS disks are Not Supported on both
#               Bsv2 and Basv2 (verified on Microsoft Learn).
#     + $7.30   to  + $14.60   Load Balancer rule overage, per the count above.
#
# ============================================================================ #
# D. GETTING BACK UNDER BUDGET
# ============================================================================ #
#
#   $1,000 credit / $109.61 = 9.1 months.  The plan targets ~$83/mo to spread
#   the credit across a full 12 months.
#
#   *** THE PLAN'S PREFERRED LEVER IS NOT AVAILABLE. ***
#   AZURE-MIGRATION-PLAN.md section 4 recommends "try the RI first" - a 1-year
#   Reserved Instance on the B2as_v2, ~-$22/mo. This subscription's quotaId is
#   `Sponsored_2016-01-01` (Azure Sponsorship), and Sponsorship subscriptions
#   generally cannot purchase Reserved Instances or Marketplace items. Design
#   nothing that depends on an RI until someone confirms otherwise in writing.
#
#   Levers that ARE available, cheapest-pain first:
#
#   1. Do not expose NATS on the public LB.            -$7.30/mo   no downside
#      NATS is ClusterIP-only per CLAUDE.md anyway.
#
#   2. system_node_os_disk_size_gb = 32 (P4 not P6).   -$4.93/mo   modest risk
#      Leaves ~25 GiB of image cache. The image cleaner is already enabled,
#      which makes this safer than it would otherwise be.
#
#   3. Platform PostgreSQL in-cluster on a PVC          -$16.09/mo  REGRESSION
#      instead of Flexible Server.
#      This is the plan's fallback lever. It gives back PITR and automated
#      backups - the durability win this migration is partly for - and would
#      need an hourly pg_dump CronJob to a dedicated R2 bucket to partially
#      compensate. Take lever 4 before this one.
#
#   4. hostNetwork ingress-nginx, no Standard LB.      -$25.55/mo  fiddly
#      Binds ports directly on the node. Kills the LB bill entirely, but the
#      public IP must then attach to the node (or a node public IP), which
#      forfeits the "static IP survives node replacement" property that
#      public-ip.tf is built around. Only worth it if 1+2 are not enough.
#
#   Levers 1 + 2 alone:  $109.61 -> $97.38/mo  =  10.3 months of credit.
#   Levers 1 + 2 + 4:    $109.61 -> $71.83/mo  =  13.9 months of credit.
#
# ============================================================================ #
# E. WHAT IS DELIBERATELY NOT PROVISIONED
# ============================================================================ #
#
#   Azure Container Registry     - GHCR stays, and is free. ~$5/mo saved.
#   Azure Blob for customer data - object storage is Cloudflare R2. Blob is not
#                                  S3-compatible and all four coded storage
#                                  providers speak S3.
#   Log Analytics                - $69-$207/mo. See monitoring.tf.
#   Azure Key Vault              - owned by the secret-management workstream.
#                                  Not guessed at here; see README.md.
#   NAT Gateway                  - ~$32/mo. Not needed at this egress volume.
#   DDoS Network Protection      - ~$2,944/mo.
#   VPN / Bastion for DB access  - ~$27/mo+. Use `az aks command invoke`.
###############################################################################

locals {
  # ---- Verified East US retail unit prices, 2026-08-09 --------------------- #
  price_b2as_v2_per_month   = 54.90 # Standard_B2as_v2, Linux, PAYG
  price_b2ls_v2_spot_month  = 27.33 # Standard_B2ls_v2 Spot ($0.03744/h)
  price_public_ip_per_month = 3.65  # Standard static IPv4 ($0.005/h)
  price_private_dns_zone    = 0.50  # per zone, first 25
  price_pg_b1ms_compute     = 12.41 # B_Standard_B1ms compute
  price_pg_storage_per_gib  = 0.115 # $/GiB/mo
  price_tf_state_storage    = 0.01  # Hot LRS blob, <1 MB
  price_lb_included_5_rules = 18.25 # $0.025/h
  price_lb_overage_per_rule = 7.30  # $0.010/h
  price_pvc_data_tier_total = 6.00  # 2 x E4 + 2 x E2 StandardSSD LRS

  # Managed OS disk tiers, by size (AKS selects Premium SSD for premium-capable
  # VM sizes, and azurerm exposes no OS-disk-SKU knob).
  price_os_disk_by_size = {
    32  = 5.28  # P4
    64  = 10.21 # P6
    128 = 19.71 # P10
  }

  # Falls back to a linear estimate from P6 for a non-standard size rather than
  # reporting $0 and quietly understating the bill.
  system_os_disk_cost = try(
    local.price_os_disk_by_size[var.system_node_os_disk_size_gb],
    var.system_node_os_disk_size_gb / 64 * 10.21,
  )

  # ---- Steady-state monthly cost of what THIS configuration creates -------- #
  cost_compute_system   = local.price_b2as_v2_per_month * var.system_node_min_count
  cost_os_disk_system   = local.system_os_disk_cost * var.system_node_min_count
  cost_compute_spot     = local.price_b2ls_v2_spot_month * var.spot_node_min_count
  cost_postgres_storage = var.postgres_storage_mb / 1024 * local.price_pg_storage_per_gib

  monthly_cost_terraform_managed = (
    local.cost_compute_system +
    local.cost_os_disk_system +
    local.cost_compute_spot +
    local.price_public_ip_per_month +
    local.price_private_dns_zone +
    local.price_pg_b1ms_compute +
    local.cost_postgres_storage
  )

  # ---- Later phases, on the bill but not in this state -------------------- #
  # Low: 5 LB rules + 1 outbound = 6 -> 1 overage. High: NATS public -> 2.
  cost_load_balancer_low  = local.price_lb_included_5_rules + local.price_lb_overage_per_rule
  cost_load_balancer_high = local.price_lb_included_5_rules + (2 * local.price_lb_overage_per_rule)

  monthly_cost_later_phases_low = local.cost_load_balancer_low + local.price_pvc_data_tier_total
  monthly_cost_later_phases_high = (
    local.cost_load_balancer_high + local.price_pvc_data_tier_total
  )

  monthly_cost_total_low = (
    local.monthly_cost_terraform_managed +
    local.price_tf_state_storage +
    local.monthly_cost_later_phases_low
  )
  monthly_cost_total_high = (
    local.monthly_cost_terraform_managed +
    local.price_tf_state_storage +
    local.monthly_cost_later_phases_high
  )
}
