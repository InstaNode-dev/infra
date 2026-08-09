###############################################################################
# Azure Database for PostgreSQL - Flexible Server, with the two platform
# databases on one server.
#
# COST SUMMARY for this file:
#   Compute B_Standard_B1ms (1 vCPU / 2 GiB)   $12.41/mo
#   Storage 32 GiB @ $0.115/GiB/mo              $3.68/mo
#   Backup storage, 7-day PITR                  $0.00/mo  (Azure includes backup
#                                                          storage up to 100% of
#                                                          provisioned storage;
#                                                          overage is $0.095/GB/mo)
#   Private DNS zone                            $0.50/mo  (billed in network.tf)
#   ------------------------------------------------------
#   Total                                      $16.09/mo
#   East US, verified via prices.azure.com 2026-08-09.
#
# --------------------------------------------------------------------------- #
# DECISION 1: VNet integration (private access), NOT public access + firewall.
# --------------------------------------------------------------------------- #
#
# COST DELTA: +$0.50/mo, entirely the private DNS zone. Server compute and
# storage are billed identically either way, and VNet integration itself is
# free. There is no private endpoint charge - Flexible Server private access
# uses subnet delegation (VNet injection), not a Private Endpoint, so the
# ~$7.30/mo private endpoint fee does not apply.
#
# WHY, for a security-conscious production restart:
#
#   * The platform database holds teams, users, API tokens and AES-256-GCM
#     encrypted customer connection strings. With public access it is reachable
#     from the entire internet, gated only by a firewall rule list and a
#     password. With VNet integration it has NO PUBLIC ENDPOINT AT ALL - the
#     FQDN resolves only inside linked VNets. Credential compromise alone stops
#     being sufficient for data access.
#
#   * The firewall-rule alternative is fragile in this specific topology.
#     Cluster egress SNATs through the AKS-managed Load Balancer's outbound
#     public IP, which is created and owned by AKS in the node resource group -
#     not the static ingress IP in public-ip.tf. Its value is not known at plan
#     time, and it changes if the cluster is rebuilt. The firewall rule would
#     have to be discovered and reapplied after every cluster lifecycle event,
#     and the fallback most people reach for - the 0.0.0.0 "allow Azure
#     services" rule - opens the server to every Azure tenant, not just ours.
#
#   * It closes the class of finding this migration exists to fix. GAP-AUDIT
#     2026-06-10 recorded customer data ports publicly reachable. Rebuilding
#     with the platform database on a public endpoint would carry that forward
#     on day one.
#
# THE COST, STATED PLAINLY - THIS IS IRREVERSIBLE:
#
#   * Public/private access is fixed AT CREATION. A Flexible Server created with
#     a delegated subnet CANNOT be switched to public access later, and vice
#     versa. Changing it means creating a new server and restoring into it.
#     Decide before the first apply, not after.
#
#   * No `psql` from a laptop. The server is unreachable outside the VNet.
#     Working paths, in preference order:
#       1. In-cluster migrator Job - already how the 69 migrations run (Phase 5).
#       2. `az aks command invoke` - run_command_enabled is true in aks.tf:
#            az aks command invoke -g <rg> -n <cluster> \
#              --command "psql 'postgresql://...' -c '\\dt'"
#       3. A throwaway jump pod:
#            kubectl run pgcli --rm -it --image=postgres:16-alpine -- \
#              psql "postgresql://<user>@<fqdn>/instant_platform?sslmode=require"
#       4. A VPN gateway into the VNet (~$27/mo) - not provisioned; out of scope.
#
#   * Terraform itself is unaffected. Every resource here is created through the
#     ARM control plane, including the two databases below, so `apply` works
#     from anywhere without network reachability to the server.
#
# --------------------------------------------------------------------------- #
# DECISION 2: two databases on ONE server.
# --------------------------------------------------------------------------- #
#
# instant_platform and provisioner_db share this server. That retires the
# standalone droplet at 161.35.111.84, which held provisioner_db with no
# backups and no failover - recorded as a single point of failure in GAP-AUDIT
# R5 and in AZURE-MIGRATION-PLAN.md section 3.
#
# The marginal cost is $0.00: a second database on an existing server is free,
# and it inherits this server's 7-day PITR. A P1 durability gap closes as a side
# effect of the migration rather than as a project.
#
# The trade-off is a shared fate domain - one server restart affects both. On
# the previous topology a provisioner_db outage already took provisioning down,
# and the droplet had strictly worse availability, so this is not a regression.
###############################################################################

resource "azurerm_postgresql_flexible_server" "main" {
  name                = local.postgres_server_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  version             = var.postgres_version

  sku_name          = var.postgres_sku_name
  storage_mb        = var.postgres_storage_mb
  auto_grow_enabled = var.postgres_auto_grow_enabled
  zone              = var.postgres_availability_zone

  administrator_login = var.postgres_admin_username

  # Plaintext in Terraform state - which is why the state backend is Azure
  # Storage with RBAC and versioning, not a local file. See versions.tf.
  administrator_password = var.postgres_admin_password

  # 7-day point-in-time restore. This is the durability promise the platform
  # sells on paid tiers, and the reason this is a managed server rather than a
  # pod on a PVC.
  backup_retention_days        = var.postgres_backup_retention_days
  geo_redundant_backup_enabled = var.postgres_geo_redundant_backup_enabled

  # Private access. All three settings move together - a delegated subnet
  # requires public access off, and the private DNS zone is how the FQDN
  # resolves from inside the VNet.
  delegated_subnet_id           = azurerm_subnet.postgres.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false

  authentication {
    password_auth_enabled = true

    # Microsoft Entra authentication would remove the shared admin password
    # entirely. Left off because it needs tenant-level identity decisions that
    # belong to the secret-management workstream, not to this file.
    # TODO(secret-management): revisit with that workstream.
    active_directory_auth_enabled = false
  }

  maintenance_window {
    # Sunday 06:00 UTC = 02:00 US Eastern - the low point for a US-facing
    # developer platform. Without this, Azure picks a window for you.
    day_of_week  = 0
    start_hour   = 6
    start_minute = 0
  }

  tags = local.common_tags

  # The zone must exist before the server is injected into the delegated subnet.
  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]

  lifecycle {
    ignore_changes = [
      # When var.postgres_availability_zone is null Azure assigns a zone. Without
      # this, every subsequent plan proposes moving the server back to "no zone",
      # which would be a destroy-and-recreate of the platform database.
      zone,
    ]
  }

  # HARDENING, deliberately NOT enabled yet:
  #
  #   lifecycle { prevent_destroy = true }
  #
  # Correct from Phase 9 sign-off onward, once this server holds real state.
  # Left off during build-out because prevent_destroy cannot be driven by a
  # variable and would block the destroy-and-retry loop a greenfield build
  # needs. See README.md "Hardening after Phase 9".
}

###############################################################################
# Databases.
#
# COST: $0.00/mo each - databases on an existing server are free.
#
# collation "en_US.utf8" and charset UTF8 match the PostgreSQL defaults the
# application has always run against.
###############################################################################

resource "azurerm_postgresql_flexible_server_database" "platform" {
  name      = var.postgres_platform_database_name
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_postgresql_flexible_server_database" "provisioner" {
  name      = var.postgres_provisioner_database_name
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

###############################################################################
# Server parameters.
###############################################################################

# Reject any connection that is not TLS. The application already builds its DSN
# with sslmode=require (AZURE-MIGRATION-PLAN.md section 6.2); this makes the
# server refuse anything less rather than trusting every client to ask.
#
# NOTE: this is ON by default on Flexible Server. It is declared so that the
# setting is visible, reviewable and enforced by Terraform rather than assumed.
resource "azurerm_postgresql_flexible_server_configuration" "require_secure_transport" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "on"
}

###############################################################################
# PHASE 5 GOTCHAS - not Terraform bugs, but they will bite during cutover.
#
# 1. max_connections on B_Standard_B1ms defaults to 35.
#
#    Four services connect to this server: instant-api, instant-worker (River,
#    which holds its own pool), instant-provisioner, and the migrator Job. If
#    each opens a default-sized pool, the fourth service fails to connect with
#    "sorry, too many clients already" - and it will look like a networking
#    problem, not a pool-sizing problem.
#
#    Size the pools explicitly in Phase 5 (leave headroom for Azure's own
#    monitoring connections), or raise the parameter:
#
#      resource "azurerm_postgresql_flexible_server_configuration" "max_connections" {
#        name      = "max_connections"
#        server_id = azurerm_postgresql_flexible_server.main.id
#        value     = "100"
#      }
#
#    Raising it is a STATIC parameter change: the provider will restart the
#    server (see providers.tf). Each connection also costs memory on a 2 GiB
#    instance, so raise it deliberately rather than reflexively.
#
# 2. Extensions must be allowlisted before CREATE EXTENSION works.
#
#    Flexible Server blocks extensions unless they are listed in the
#    `azure.extensions` server parameter.
#
#    RESOLVED 2026-08-09. The enumeration this comment asked for was run
#    against the api repo:
#
#      $ grep -rniE 'create extension' api/internal/db/migrations/
#      010_team_invitations.sql:15:CREATE EXTENSION IF NOT EXISTS pgcrypto;
#
#    Exactly one, across all 72 migrations. The resource is now declared at
#    the bottom of this file - it is NOT optional.
#
#    Why this was a hard blocker: migrations run at api boot
#    (api/main.go:132) and a failure is fatal. Without the allowlist entry,
#    migration 010 fails, the api CrashLoopBackOffs, and NOTHING in the
#    platform starts. It would have been the first thing to break on a
#    cluster that otherwise came up perfectly.
#
#    Note this is the PLATFORM database. pgvector is a CUSTOMER data-tier
#    concern (pgvector/pgvector:pg16 in the in-cluster postgres-customers pod)
#    and is not needed here.
#
# 3. The connection string for k8s Secrets (AZURE-MIGRATION-PLAN.md 6.2):
#
#      DATABASE_URL=postgresql://<admin>@<fqdn>:5432/instant_platform?sslmode=require
#      PROVISIONER_DATABASE_URL=postgresql://<admin>@<fqdn>:5432/provisioner_db?sslmode=require
#
#    `terraform output postgres_connection_string_template` prints these with
#    the FQDN filled in and the password left as a placeholder.
###############################################################################

###############################################################################
# Extension allowlist
#
# Azure PostgreSQL Flexible Server refuses `CREATE EXTENSION` for anything not
# named in the `azure.extensions` server parameter, which is EMPTY by default.
#
# Enumerated 2026-08-09 across all 72 platform migrations:
#   api/internal/db/migrations/010_team_invitations.sql:15
#     CREATE EXTENSION IF NOT EXISTS pgcrypto;
#
# That is the complete set - one extension. Command to re-verify if migrations
# are added later (this list must be kept in sync, it is a rule-22 contract
# surface):
#
#   grep -rniE 'create extension' api/internal/db/migrations/
#
# Migrations run at api boot (api/main.go:132) and are a hard gate: without
# this resource, migration 010 fails and every api pod CrashLoopBackOffs.
#
# pgvector is deliberately NOT here - it is a CUSTOMER data-tier concern,
# served by the pgvector/pgvector:pg16 image in the in-cluster
# postgres-customers pod, not by this platform database.
###############################################################################

resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "PGCRYPTO"
}
