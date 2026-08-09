###############################################################################
# AKS cluster: Free-tier control plane, one system node pool, one Spot build
# pool that scales to zero.
#
# COST SUMMARY for this file:
#   Control plane (sku_tier = "Free")          $0.00/mo   no SLA, no charge
#   System pool 1 x Standard_B2as_v2          $54.90/mo   (per node, x1 at min)
#   System pool OS disk 64 GiB (Premium P6)   $10.21/mo   (per node)
#   Spot pool, min_count = 0                   $0.00/mo   idle
#   Spot pool while 1 node is up              ~$27.33/mo  prorated to seconds
#   Spot pool OS disk while a node exists     ~$10.21/mo  prorated to seconds
#   Standard Load Balancer                        see costs.tf - AKS creates it
#                                                 in the node resource group at
#                                                 Phase 6, NOT here
#   All prices East US, verified prices.azure.com 2026-08-09.
#
# NETWORK POLICY - READ THIS BEFORE CHANGING network_profile
#
#   This cluster DOES enforce NetworkPolicy. `network_policy` is set from
#   var.network_policy_engine, default "cilium".
#
#   This is load-bearing, not decoration. infra/k8s/data/networkpolicy.yaml
#   ships four networking.k8s.io/v1 NetworkPolicy objects that implement the
#   data-tier ingress lockdown (GAP-AUDIT S2). AKS accepts NetworkPolicy objects
#   on a cluster with no policy engine and SILENTLY ENFORCES NOTHING: `kubectl
#   get netpol` looks correct, `kubectl describe` looks correct, and every pod
#   in the cluster can still reach postgres-customers. Tenant isolation would be
#   theatre.
#
#   The engine can ONLY be chosen at cluster creation. It cannot be added to a
#   running cluster - retrofitting means replacing the cluster, which means a
#   new node resource group, a new Load Balancer, and (unless the public IP is
#   kept, see public-ip.tf) a DNS migration. Getting it right here is cheap;
#   getting it wrong is a rebuild.
#
# CAPACITY BUDGET, against ~1.9 vCPU / ~5.5 GiB allocatable on one B2as_v2:
#   measured platform requests                ~1.35 vCPU / ~2.2 GiB
#   That headroom is why azure_policy_enabled is false and why the Azure Files
#   CSI driver is disabled below. Each add-on eaten now is a node upgrade later.
###############################################################################

resource "azurerm_kubernetes_cluster" "main" {
  name                = local.aks_cluster_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = local.aks_dns_prefix
  kubernetes_version  = var.kubernetes_version

  # Free tier: $0 control plane, no uptime SLA. Matches the accepted posture in
  # AZURE-MIGRATION-PLAN.md section 8 - the DigitalOcean cluster had no HA
  # either (GAP-AUDIT R10). Standard tier is $73/mo and would consume most of
  # the monthly budget to insure a single-node cluster.
  sku_tier = "Free"

  # Explicitly named so cost exports are readable and the AKS-owned boundary is
  # obvious. AKS creates the VMSS, the Standard Load Balancer and node OS disks
  # here. Do not hand-edit this resource group.
  node_resource_group = local.node_resource_group_name

  # Free, and required later if workloads authenticate to Azure services
  # (e.g. Key Vault) without static credentials. Enabling now avoids a cluster
  # update when the secret-management workstream lands.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  role_based_access_control_enabled = true

  # Kept enabled: `az aks command invoke` is the break-glass path for reaching
  # the PostgreSQL server, which has no public endpoint (see postgres.tf).
  run_command_enabled = true

  # NOT disabled. CI authenticates with a ci-deployer ServiceAccount kubeconfig
  # (infra/k8s/ci-deployer-rbac.yaml), which is unaffected either way, but
  # `az aks get-credentials --admin` remains the operator's recovery path if
  # Entra access is ever misconfigured. Revisit once Entra RBAC is wired.
  local_account_disabled = false

  automatic_upgrade_channel = var.automatic_upgrade_channel
  node_os_upgrade_channel   = var.node_os_upgrade_channel

  # Removes unreferenced images from nodes. On a deliberately undersized OS disk
  # this is what stops image-cache growth from causing disk-pressure evictions,
  # especially with customer deploy images being pulled continuously.
  image_cleaner_enabled        = true
  image_cleaner_interval_hours = var.image_cleaner_interval_hours

  # Gatekeeper costs roughly 200m CPU / 500Mi across its pods. On a node with
  # ~1.9 vCPU allocatable against ~1.35 vCPU of requests, that is most of the
  # remaining headroom, spent on a policy engine nothing currently uses.
  azure_policy_enabled = false

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks_control_plane.id]
  }

  # REQUIRED in azurerm 5.0+. This block did not have to be present in 4.x, so
  # every pre-5.0 AKS example on the internet fails validation with
  # "At least 1 node_provisioning_profile blocks are required".
  #
  # "Manual" = the node pools declared in this file, scaled by the cluster
  # autoscaler. That is what the capacity model and the Spot quota ceiling in
  # QUOTA.md assume.
  #
  # "Auto" would enable Node Auto Provisioning (Karpenter): AKS would pick VM
  # SKUs and sizes itself, on demand. Attractive in principle, wrong here on
  # three counts - it supersedes the cluster autoscaler and the explicit pool
  # sizing below, it can select SKUs outside the Basv2/Bsv2 families this
  # subscription has quota for, and unconstrained SKU selection against a fixed
  # $1,000 credit is exactly the failure mode budget.tf exists to catch.
  node_provisioning_profile {
    mode = "Manual"
  }

  # ------------------------------------------------------------------------- #
  # System node pool - runs EVERY platform workload.
  #
  # only_critical_addons_enabled is deliberately false (the default). Setting it
  # true taints this pool CriticalAddonsOnly=true:NoSchedule, which on a
  # single-pool cluster leaves nowhere for instant-api to run.
  # ------------------------------------------------------------------------- #
  default_node_pool {
    name    = "system"
    vm_size = var.system_node_vm_size

    auto_scaling_enabled = true
    min_count            = var.system_node_min_count
    max_count            = var.system_node_max_count

    vnet_subnet_id = azurerm_subnet.aks_nodes.id
    max_pods       = var.system_node_max_pods

    # OS DISK: "Managed", not "Ephemeral" - VERIFIED, not assumed.
    #
    # Ephemeral OS disks would be free (they live on the host's local/cache
    # disk), so they are the obvious choice. They are NOT AVAILABLE on either
    # SKU used here. From Microsoft Learn, Basv2-series and Bsv2-series pages
    # (retrieved 2026-08-09), both state identically:
    #     Local Storage: None      "No local storage present in this series."
    #     Feature support -> Ephemeral OS Disk: Not Supported
    # Ephemeral OS requires a local temp/cache disk to place the image on, and
    # the v2 B-series has none. Setting os_disk_type = "Ephemeral" here would
    # fail at apply time.
    #
    # Consequence: the OS disk is a billed managed disk. See
    # var.system_node_os_disk_size_gb for the size/tier/cost table.
    os_disk_type    = "Managed"
    os_disk_size_gb = var.system_node_os_disk_size_gb

    os_sku = "Ubuntu"

    # Required for in-place rotation when an immutable node pool property
    # changes; without it such a change fails the apply. Max 12 characters.
    temporary_name_for_rotation = "systmp"

    upgrade_settings {
      # With min_count = 1 a percentage surge rounds to 1 node anyway. Stating
      # "1" makes the upgrade behaviour explicit: add a node, drain, remove -
      # rather than drain-in-place, which would be a full outage.
      max_surge = "1"
    }

    tags = local.common_tags
  }

  network_profile {
    network_plugin = "azure"

    # Azure CNI OVERLAY. Pods get addresses from pod_cidr, outside the VNet, so
    # the node subnet can never run out of pod IPs. kubenet, the other way to
    # decouple pod IPs from the VNet, is deprecated on AKS.
    network_plugin_mode = "overlay"

    # See the NETWORK POLICY block at the top of this file. "cilium" also
    # requires network_data_plane = "cilium"; calico and azure run on the
    # standard Azure data plane.
    network_policy     = var.network_policy_engine
    network_data_plane = var.network_policy_engine == "cilium" ? "cilium" : "azure"

    load_balancer_sku = "standard"

    # Egress via the AKS-managed Standard Load Balancer. The alternative,
    # outbound_type = "userAssignedNATGateway", costs roughly $32/mo more and
    # only pays for itself under SNAT port exhaustion, which this workload is
    # nowhere near. Additive later if needed.
    outbound_type = "loadBalancer"

    pod_cidr       = var.pod_cidr
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip
  }

  storage_profile {
    # Required for `managed-csi` PVCs - the storage class every data-tier
    # workload moves to (AZURE-MIGRATION-PLAN.md section 6.1).
    disk_driver_enabled = true

    # ReadWriteMany is unused by this platform; the driver's pods are pure
    # overhead on a node with ~5.5 GiB allocatable.
    file_driver_enabled = var.enable_azure_file_csi_driver

    # Needed by the backup ladder if it ever takes volume snapshots.
    snapshot_controller_enabled = true

    # Azure Blob CSI: not used. Object storage is Cloudflare R2, which the
    # application speaks over the S3 API (AZURE-MIGRATION-PLAN.md section 5.1).
    blob_driver_enabled = false
  }

  auto_scaler_profile {
    # least-waste picks the node group that leaves the least idle CPU/memory
    # after scheduling - the right expander when pools have different shapes.
    expander = "least-waste"

    # THIS ONE MATTERS FOR COST. Default is true, which means the autoscaler
    # REFUSES to remove any node running a pod with an emptyDir volume. Kaniko
    # build pods use emptyDir for the build context, so with the default the
    # Spot build node would be pinned up long after builds finished and the
    # scale-to-zero design would quietly never happen.
    skip_nodes_with_local_storage = false

    # Keep the default protection for kube-system pods; the system pool has
    # min_count = 1 so it cannot be scaled away regardless.
    skip_nodes_with_system_pods = true

    # Return the build node faster than the 10-minute default once idle.
    scale_down_unneeded              = "5m"
    scale_down_delay_after_add       = "5m"
    scale_down_utilization_threshold = "0.5"
  }

  # Container Insights. Disabled by default - see var.enable_container_insights
  # for the $69-$207/mo arithmetic that keeps it that way.
  dynamic "oms_agent" {
    for_each = var.enable_container_insights ? [1] : []

    content {
      log_analytics_workspace_id      = azurerm_log_analytics_workspace.main[0].id
      msi_auth_for_monitoring_enabled = true
    }
  }

  tags = local.common_tags

  # The role assignments must exist before the control plane tries to place node
  # NICs in the BYO subnet or attach the BYO public IP. Terraform infers the
  # identity dependency but not the grants, so they are declared.
  depends_on = [
    azurerm_role_assignment.aks_subnet_network_contributor,
    azurerm_role_assignment.aks_public_ip_network_contributor,
  ]

  lifecycle {
    ignore_changes = [
      # AKS patches the control plane under automatic_upgrade_channel. Without
      # this, every plan after an auto-upgrade proposes downgrading the cluster
      # back to the pinned value.
      kubernetes_version,
      # Likewise for node images under node_os_upgrade_channel.
      default_node_pool[0].orchestrator_version,
    ]
  }
}

###############################################################################
# Spot node pool - Kaniko build jobs and customer deploy pods.
#
# QUOTA CEILING - DO NOT RAISE max_count WITHOUT A QUOTA INCREASE
#
#   Measured on subscription 73ae3d2a-5847-48f2-bcea-10bd3e1914f6, East US,
#   2026-08-09, via `az vm list-usage --location eastus`:
#
#       Total Regional Low-priority vCPUs      0 / 3
#
#   Spot and low-priority VMs consume that 3-vCPU quota. Standard_B2ls_v2 is
#   2 vCPU, so THREE vCPU allows exactly ONE node. max_count = 2 would need
#   4 vCPU: the autoscaler would attempt a second node, Azure would reject the
#   scale-up on quota, and builds would queue behind a scale-up that can never
#   succeed - a failure that looks like "builds are slow", not like a quota
#   error.
#
#   To raise it: request a Low-priority vCPU quota increase for East US first,
#   confirm with `az vm list-usage`, then raise var.spot_node_max_count.
#   See QUOTA.md.
#
#   (The system pool is unaffected: Standard Basv2 Family vCPUs is 0 / 65, so
#   autoscaling 1->3 x B2as_v2 = 6 vCPU has ample headroom.)
#
# SCHEDULING - workloads must opt in to this pool with BOTH:
#
#   nodeSelector:
#     instanode.dev/workload: build
#   tolerations:
#     # applied automatically by AKS to every Spot node pool
#     - key: kubernetes.azure.com/scalesetpriority
#       operator: Equal
#       value: spot
#       effect: NoSchedule
#     # applied by node_taints below
#     - key: instanode.dev/workload
#       operator: Equal
#       value: build
#       effect: NoSchedule
#
#   The AKS Spot taint alone would let ANY spot-tolerant pod land here. The
#   second taint makes this pool opt-in for build/deploy work specifically.
#
#   Anything scheduled here MUST tolerate eviction: Spot nodes are reclaimed
#   with 30 seconds' notice. Kaniko jobs are safe (a Job retries). Long-lived
#   customer deploy Deployments will be rescheduled and briefly unavailable -
#   move them to the system pool if that ever becomes unacceptable.
###############################################################################

resource "azurerm_kubernetes_cluster_node_pool" "build" {
  name                  = "build"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.spot_node_vm_size
  mode                  = "User"

  priority = "Spot"

  # Delete, not Deallocate. A deallocated node still bills for its OS disk and
  # holds quota while contributing nothing. Build capacity is disposable.
  eviction_policy = "Delete"

  # -1 = pay up to the on-demand price, so eviction only ever happens for
  # capacity, never for price. See var.spot_max_price.
  spot_max_price = var.spot_max_price

  auto_scaling_enabled = true
  min_count            = var.spot_node_min_count # 0 - this is where the saving is
  max_count            = var.spot_node_max_count # 1 - low-priority vCPU quota
  node_count           = var.spot_node_min_count

  vnet_subnet_id = azurerm_subnet.aks_nodes.id

  # Ephemeral OS is unavailable on Bsv2 as well - same verified Microsoft Learn
  # source as the system pool. See the comment in default_node_pool.
  os_disk_type    = "Managed"
  os_disk_size_gb = var.spot_node_os_disk_size_gb
  os_sku          = "Ubuntu"

  # The AKS Spot taint (kubernetes.azure.com/scalesetpriority=spot:NoSchedule)
  # is added by Azure automatically and is deliberately NOT repeated here -
  # declaring it in Terraform as well produces a permanent diff.
  node_taints = ["instanode.dev/workload=build:NoSchedule"]

  node_labels = {
    "instanode.dev/workload" = "build"
  }

  tags = local.common_tags

  lifecycle {
    ignore_changes = [
      orchestrator_version,
      # The autoscaler owns the live count; Terraform must not fight it.
      node_count,
    ]
  }
}
