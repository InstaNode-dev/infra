###############################################################################
# Input variables.
#
# Defaults encode the decisions in docs/sessions/2026-08-09/AZURE-MIGRATION-PLAN.md.
# Anything with a cost consequence carries the real East US retail price in its
# description, so `terraform console` / docs generation surfaces it.
###############################################################################

# --------------------------------------------------------------------------- #
# Subscription / naming
# --------------------------------------------------------------------------- #

variable "subscription_id" {
  description = <<-EOT
    Azure subscription ID that carries the $1,000 Founders Hub credit.
    Prefer supplying this as ARM_SUBSCRIPTION_ID rather than in a tfvars file.
    Find it with: az account show --query id -o tsv
  EOT
  type        = string
}

variable "project" {
  description = "Project slug used to build every resource name."
  type        = string
  default     = "instanode"

  validation {
    condition     = can(regex("^[a-z0-9]{3,16}$", var.project))
    error_message = "project must be 3-16 lowercase alphanumeric characters."
  }
}

variable "environment" {
  description = "Environment slug used to build every resource name (prod, staging, ...)."
  type        = string
  default     = "prod"

  validation {
    condition     = can(regex("^[a-z0-9]{2,10}$", var.environment))
    error_message = "environment must be 2-10 lowercase alphanumeric characters."
  }
}

variable "location" {
  description = <<-EOT
    Azure region. East US per AZURE-MIGRATION-PLAN.md section 5.2: matches the
    nyc3 latency profile for US customers, cheapest tier, broadest SKU
    availability. Every price annotation in this configuration is East US;
    changing this invalidates the cost model in costs.tf.
  EOT
  type        = string
  default     = "eastus"
}

variable "name_suffix" {
  description = <<-EOT
    Optional suffix appended to globally-unique resource names (the PostgreSQL
    server name is global across all of Azure). Leave empty unless a name
    collision forces it; a non-empty value here changes the database FQDN.
  EOT
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}

# --------------------------------------------------------------------------- #
# Networking
# --------------------------------------------------------------------------- #

variable "vnet_address_space" {
  description = <<-EOT
    VNet address space. Must not overlap service_cidr or pod_cidr.
    Deliberately 10.60.0.0/16 rather than the 10.0.0.0/16 default so it cannot
    collide with a customer VNet or a future peering.
  EOT
  type        = list(string)
  default     = ["10.60.0.0/16"]
}

variable "aks_nodes_subnet_cidr" {
  description = <<-EOT
    Subnet for AKS node NICs. With Azure CNI Overlay, PODS DO NOT CONSUME
    ADDRESSES HERE - only nodes and internal load balancer frontends do. A /22
    (1019 usable) is enormous overkill for a 1-3 node cluster and costs nothing.
  EOT
  type        = string
  default     = "10.60.0.0/22"
}

variable "postgres_subnet_cidr" {
  description = <<-EOT
    Subnet DELEGATED to Microsoft.DBforPostgreSQL/flexibleServers. A delegated
    subnet cannot host any other resource type, so it gets its own range.
    Azure reserves 5 addresses per subnet; /28 is the documented minimum for
    Flexible Server. /24 leaves room for read replicas later.
  EOT
  type        = string
  default     = "10.60.4.0/24"
}

variable "pod_cidr" {
  description = <<-EOT
    Overlay pod CIDR (Azure CNI Overlay). These addresses live only inside the
    cluster and are NOT routable in the VNet, which is exactly why overlay is
    chosen: pod-IP exhaustion becomes impossible, and kubenet is deprecated.
    Must not overlap vnet_address_space or service_cidr.
  EOT
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "Kubernetes ClusterIP range. Must not overlap vnet_address_space or pod_cidr."
  type        = string
  default     = "10.61.0.0/16"
}

variable "dns_service_ip" {
  description = "CoreDNS ClusterIP. Must be inside service_cidr and must not be the network address."
  type        = string
  default     = "10.61.0.10"
}

variable "network_policy_engine" {
  description = <<-EOT
    NetworkPolicy enforcement engine. THIS IS NOT OPTIONAL FOR THIS PLATFORM:
    infra/k8s/data/networkpolicy.yaml ships four networking.k8s.io/v1
    NetworkPolicy objects, and AKS SILENTLY IGNORES NetworkPolicy resources when
    no engine is installed - the data-tier lockdown would appear applied and
    enforce nothing.

      cilium - Azure CNI Powered by Cilium. Azure's recommended default for new
               overlay clusters, eBPF dataplane, $0 extra. DEFAULT.
      calico - Conservative fallback, more widely deployed, runs extra pods.
      azure  - Azure NPM. Fewest features; only if the other two misbehave.

    The repo's policies are plain upstream NetworkPolicy with no Calico or
    Cilium CRDs (verified), so all three engines satisfy them. Changing this
    value REPLACES the cluster.
  EOT
  type        = string
  default     = "cilium"

  validation {
    condition     = contains(["cilium", "calico", "azure"], var.network_policy_engine)
    error_message = "network_policy_engine must be one of: cilium, calico, azure."
  }
}

# --------------------------------------------------------------------------- #
# AKS
# --------------------------------------------------------------------------- #

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes minor version, e.g. "1.31". Leave null to take the AKS default
    for the region at create time (recommended for a greenfield build - it is
    always a supported version). List options with:
      az aks get-versions --location eastus --output table
  EOT
  type        = string
  default     = null
}

variable "system_node_vm_size" {
  description = <<-EOT
    System node pool VM size. Standard_B2as_v2 = 2 vCPU / 8 GiB, $54.90/mo
    (East US, Linux, PAYG, verified via prices.azure.com 2026-08-09).
    Roughly 1.9 vCPU / 5.5 GiB allocatable after AKS reservations, against a
    measured platform requirement of ~1.35 vCPU / ~2.2 GiB.
  EOT
  type        = string
  default     = "Standard_B2as_v2"
}

variable "system_node_min_count" {
  description = "Cluster autoscaler floor for the system pool. Must be >= 1; this pool runs every platform workload."
  type        = number
  default     = 1

  validation {
    condition     = var.system_node_min_count >= 1
    error_message = "system_node_min_count must be at least 1 - the system pool hosts all platform workloads."
  }
}

variable "system_node_max_count" {
  description = "Cluster autoscaler ceiling for the system pool. Each additional node is a further $54.90/mo while it exists."
  type        = number
  default     = 3
}

variable "system_node_os_disk_size_gb" {
  description = <<-EOT
    OS disk size for system nodes, in GiB.

    COST: AKS provisions the managed OS disk as Premium SSD for VM sizes that
    support premium storage (Basv2 does), and azurerm exposes no knob for the
    OS disk SKU - only size and Managed/Ephemeral. Sizes map to disk tiers:
        32 GiB -> P4  $5.28/mo      64 GiB -> P6  $10.21/mo
       128 GiB -> P10 $19.71/mo  (this is the AKS default for an 8 GiB VM)
    (East US retail, verified 2026-08-09.)

    64 GiB is the default here: setting it explicitly saves $9.50/mo against the
    128 GiB AKS default, while leaving ~50 GiB of image cache. 32 GiB saves a
    further $4.93/mo but leaves ~25 GiB, and kubelet starts evicting on image
    filesystem pressure at 85% - a disk-pressure eviction on a single-node
    cluster is an outage, which is not worth $4.93.
  EOT
  type        = number
  default     = 64

  validation {
    condition     = var.system_node_os_disk_size_gb >= 30
    error_message = "AKS requires an OS disk of at least 30 GiB."
  }
}

variable "system_node_max_pods" {
  description = "Max pods per system node. 110 is the upstream Kubernetes default; AKS defaults to 250 with overlay, which is meaningless on a 2 vCPU node."
  type        = number
  default     = 110
}

variable "spot_node_vm_size" {
  description = <<-EOT
    Build/deploy (Spot) node pool VM size. Standard_B2ls_v2 = 2 vCPU / 4 GiB.
    East US verified 2026-08-09: on-demand $30.37/mo, Spot $27.33/mo.

    NOTE the Spot discount on B-series is only ~10%, far from the 60-90% seen
    on D/E series. The saving here is NOT the Spot discount - it is
    spot_node_min_count = 0, which makes the pool cost $0 whenever no build is
    running. Spot is kept anyway because it is free to keep and the eviction
    semantics (rebuild the job) are correct for Kaniko.
  EOT
  type        = string
  default     = "Standard_B2ls_v2"
}

variable "spot_node_min_count" {
  description = "Autoscaler floor for the build pool. 0 = scale to zero; the pool costs nothing when idle. Do not raise without a reason."
  type        = number
  default     = 0
}

variable "spot_node_max_count" {
  description = "Autoscaler ceiling for the build pool. Each running node costs ~$27.33/mo prorated by the seconds it actually exists."
  type        = number
  default     = 2
}

variable "spot_node_os_disk_size_gb" {
  description = "OS disk size for build nodes, in GiB. Kaniko unpacks image layers to the node filesystem, so keep headroom. Billed only while a node exists."
  type        = number
  default     = 64
}

variable "spot_max_price" {
  description = <<-EOT
    Maximum hourly price for Spot nodes. -1 means "pay up to the on-demand
    price", so nodes are only ever evicted for CAPACITY, never for price. Any
    other value adds price-based eviction on top, which would make builds fail
    unpredictably for a saving of a few cents.
  EOT
  type        = number
  default     = -1
}

variable "automatic_upgrade_channel" {
  description = <<-EOT
    AKS control plane auto-upgrade channel: patch, rapid, stable, node-image, none.
    "patch" takes CVE fixes within the pinned minor and never bumps minor
    versions unattended. On a single-node cluster an upgrade drains the node;
    max_surge = 1 makes AKS add a replacement node first, so expect a brief
    second node (and its $54.90/mo prorated to minutes) during upgrades.
  EOT
  type        = string
  default     = "patch"
}

variable "node_os_upgrade_channel" {
  description = "Node OS image upgrade channel: None, Unmanaged, SecurityPatch, NodeImage. NodeImage swaps to a fresh, fully-patched image rather than patching in place."
  type        = string
  default     = "NodeImage"
}

variable "enable_azure_file_csi_driver" {
  description = <<-EOT
    Azure Files CSI driver (ReadWriteMany volumes). Disabled: the platform uses
    only ReadWriteOnce PVCs (managed-csi), and the driver's pods are pure
    overhead on a node with ~5.5 GiB allocatable. Flip to true if any workload
    ever needs RWX.
  EOT
  type        = bool
  default     = false
}

variable "image_cleaner_interval_hours" {
  description = "How often the AKS image cleaner (Eraser) removes unreferenced images. Directly protects the sized-down OS disk from image-cache disk pressure. Valid range 24-2160."
  type        = number
  default     = 24
}

# --------------------------------------------------------------------------- #
# Public IP
# --------------------------------------------------------------------------- #

variable "public_ip_dns_label" {
  description = <<-EOT
    Optional DNS label producing <label>.eastus.cloudapp.azure.com at no cost.
    Useful during Phase 6-9 to reach the ingress over a real hostname BEFORE the
    Cloudflare A records are cut over, so cert-manager and the API can be
    verified without touching production DNS. Must be globally unique in the
    region. Leave null to skip.
  EOT
  type        = string
  default     = null
}

# --------------------------------------------------------------------------- #
# PostgreSQL Flexible Server
# --------------------------------------------------------------------------- #

variable "postgres_version" {
  description = <<-EOT
    Major PostgreSQL version. The repo pins postgres:16-alpine and
    pgvector/pgvector:pg16 for the CUSTOMER data tier; 16 keeps the platform
    database on the same major as everything else that is tested.
    (postgres:17-alpine also appears in the repo - see the report note.)
  EOT
  type        = string
  default     = "16"
}

variable "postgres_sku_name" {
  description = <<-EOT
    Compute SKU. B_Standard_B1ms = 1 vCPU / 2 GiB burstable, $12.41/mo compute
    (East US, verified 2026-08-09).

    CAPACITY WARNING: B1ms defaults to max_connections = 35. The platform runs
    api + worker (River) + provisioner + migrator, each with its own pool,
    against this one server. Size those pools deliberately in Phase 5 or the
    fourth service will fail to connect. See postgres.tf.
  EOT
  type        = string
  default     = "B_Standard_B1ms"
}

variable "postgres_storage_mb" {
  description = <<-EOT
    Provisioned storage in MB. 32768 = 32 GiB, the Flexible Server minimum, at
    $0.115/GiB/mo = $3.68/mo (East US, verified 2026-08-09). Backup storage up
    to 100% of provisioned storage is included free, so a 7-day PITR window on
    a 32 GiB server costs $0 in backup storage.

    Storage can only ever be scaled UP, never down.
  EOT
  type        = number
  default     = 32768
}

variable "postgres_backup_retention_days" {
  description = "PITR window in days (7-35). 7 satisfies the plan; each extra day only costs money once backup size exceeds provisioned storage."
  type        = number
  default     = 7

  validation {
    condition     = var.postgres_backup_retention_days >= 7 && var.postgres_backup_retention_days <= 35
    error_message = "postgres_backup_retention_days must be between 7 and 35."
  }
}

variable "postgres_geo_redundant_backup_enabled" {
  description = "Geo-redundant backup. Off: it roughly doubles backup storage cost and cross-region DR is not in scope for a $1,000 budget. Cannot be changed after creation."
  type        = bool
  default     = false
}

variable "postgres_auto_grow_enabled" {
  description = "Grow storage automatically when nearly full. On: a full platform database is a total outage, and growth is billed at $0.115/GiB/mo only for what is actually used."
  type        = bool
  default     = true
}

variable "postgres_availability_zone" {
  description = <<-EOT
    Availability zone ("1", "2", "3") or null to let Azure choose. Default null:
    pinning a zone can fail an apply outright if B1ms capacity is short in that
    zone, and with no HA replica the zone choice buys nothing. The zone Azure
    picks is ignored on subsequent plans (see lifecycle in postgres.tf).
  EOT
  type        = string
  default     = null
}

variable "postgres_admin_username" {
  description = "PostgreSQL administrator login. Cannot be 'azure_superuser', 'azure_pg_admin', 'admin', 'administrator', 'root', 'guest' or 'public', and cannot start with 'pg_'."
  type        = string
  default     = "instanode_admin"
}

variable "postgres_admin_password" {
  description = <<-EOT
    PostgreSQL administrator password. NO DEFAULT - apply fails without it,
    by design.

    Supply it as an environment variable, never in a committed file:
        export TF_VAR_postgres_admin_password="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"

    Per AZURE-MIGRATION-PLAN.md section 1 this is a FRESH credential - there is
    no data to decrypt, so nothing carries over from DigitalOcean.

    This value is written to Terraform state in plaintext. That is why the state
    backend is Azure Storage with RBAC, not a local file. See versions.tf.

    TODO(secret-management): a separate workstream owns secret management for
    this platform. When it lands, this variable becomes the bootstrap-only path
    and the steady-state source should be that system (e.g. an
    ephemeral/write-only value or a rotation job), so the password stops living
    in Terraform state at all. Deliberately NOT guessed at here.
  EOT
  type        = string
  sensitive   = true
}

variable "postgres_platform_database_name" {
  description = "Platform database - teams, users, resources, onboarding_events. Owned by api/."
  type        = string
  default     = "instant_platform"
}

variable "postgres_provisioner_database_name" {
  description = <<-EOT
    Provisioner database. Co-locating it here retires the standalone,
    unbacked-up droplet at 161.35.111.84 (GAP-AUDIT R5 single point of failure)
    at zero marginal cost - it inherits this server's PITR.
  EOT
  type        = string
  default     = "provisioner_db"
}

# --------------------------------------------------------------------------- #
# Observability (OFF by default - see costs.tf)
# --------------------------------------------------------------------------- #

variable "enable_container_insights" {
  description = <<-EOT
    Container Insights / Log Analytics. DEFAULT OFF, and it should stay off.

    COST (East US, verified via prices.azure.com 2026-08-09):
      Analytics Logs ingestion  $2.30/GB
      retention beyond 31 days  $0.10/GB/mo
    Container Insights on a small AKS cluster typically ingests 1-3 GB/day, i.e.
    30-90 GB/mo, i.e. $69-$207/mo. That is between 70% and 200% of the ENTIRE
    monthly budget for this platform, for logs alone.

    The platform already ships its own telemetry to New Relic
    (infra/k8s/newrelic-prometheus-agent.yaml). Turning this on duplicates that
    at Azure retail prices. If it is ever needed, set log_analytics_daily_quota_gb
    first.
  EOT
  type        = bool
  default     = false
}

variable "log_analytics_daily_quota_gb" {
  description = "Hard daily ingestion cap in GB when enable_container_insights is true. -1 means unlimited, which at $2.30/GB is how a budget disappears. 1 GB/day = ~$69/mo ceiling."
  type        = number
  default     = 1
}

variable "log_analytics_retention_days" {
  description = "Log Analytics retention. 30 days is the free floor; anything beyond bills at $0.10/GB/mo."
  type        = number
  default     = 30
}

# --------------------------------------------------------------------------- #
# Cost guardrail (OFF by default - see budget.tf for why)
# --------------------------------------------------------------------------- #

variable "enable_cost_budget" {
  description = <<-EOT
    Create a subscription cost budget with 50/80/100% alerts. Free.

    DEFAULT FALSE because this subscription's quotaId is Sponsored_2016-01-01
    (Azure Sponsorship), and Sponsorship subscriptions have inconsistent Azure
    Cost Management support - a budget may fail to create or may create and
    never evaluate. That could not be verified without applying it. See budget.tf
    for how to confirm and enable.
  EOT
  type        = bool
  default     = false
}

variable "monthly_budget_amount" {
  description = <<-EOT
    Monthly budget in USD. 100 sits just above the modelled steady-state run
    rate (see costs.tf), so the 80% alert fires on genuine drift rather than on
    normal operation.
  EOT
  type        = number
  default     = 100
}

variable "budget_start_date" {
  description = "Budget start date, RFC3339. MUST be the first day of a month and not more than three months in the past."
  type        = string
  default     = "2026-08-01T00:00:00Z"
}

variable "budget_alert_emails" {
  description = "Recipients for budget alerts. Must be non-empty when enable_cost_budget is true."
  type        = list(string)
  default     = []
}
