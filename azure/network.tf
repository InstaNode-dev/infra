###############################################################################
# Virtual network, subnets, and the private DNS zone for PostgreSQL.
#
# COST SUMMARY for this file:
#   VNet                                  $0.00/mo  (VNets are free)
#   Subnets                               $0.00/mo
#   Private DNS zone                      $0.50/mo  (first 25 zones, verified
#                                                    prices.azure.com 2026-08-09:
#                                                    Azure DNS "Private Zone",
#                                                    $0.50/zone/month)
#   Private DNS queries                   ~$0.00/mo ($0.40 per MILLION queries;
#                                                    the platform issues a
#                                                    handful per pod start)
#   VNet <-> private DNS zone link        $0.00/mo
#
# There is no NAT Gateway and no Azure Firewall here. Cluster egress uses the
# AKS-managed Standard Load Balancer (outbound_type = "loadBalancer"), which is
# included in the load balancer cost rather than adding ~$32/mo for a NAT
# Gateway. The trade-off is SNAT port exhaustion under very high outbound
# connection counts; at this workload size that is not a live concern, and the
# fix (a NAT Gateway) is additive later.
#
# ADDRESS PLAN - three ranges that must never overlap:
#   VNet    10.60.0.0/16   node NICs, delegated PostgreSQL subnet
#   Pods    10.244.0.0/16  overlay only, not routable in the VNet
#   Service 10.61.0.0/16   ClusterIPs
###############################################################################

resource "azurerm_virtual_network" "main" {
  name                = local.vnet_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = var.vnet_address_space
  tags                = local.common_tags
}

# --------------------------------------------------------------------------- #
# AKS node subnet
#
# With Azure CNI Overlay, only NODES take addresses from this subnet - pods get
# addresses from var.pod_cidr, which lives outside the VNet entirely. That is
# the whole reason for choosing Overlay: pod-IP exhaustion (the classic Azure
# CNI failure mode, where a /22 silently caps you at ~4 nodes) cannot happen,
# and kubenet, the other way to avoid it, is deprecated.
# --------------------------------------------------------------------------- #

resource "azurerm_subnet" "aks_nodes" {
  name                 = local.aks_subnet_name
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.aks_nodes_subnet_cidr]
}

# --------------------------------------------------------------------------- #
# PostgreSQL delegated subnet
#
# Delegation hands subnet control to the PostgreSQL resource provider so it can
# inject the server's NIC. A delegated subnet CANNOT host anything else, which
# is why it is separate from the node subnet.
#
# `private_endpoint_network_policies = "Disabled"` is required for injected
# services in a delegated subnet.
# --------------------------------------------------------------------------- #

resource "azurerm_subnet" "postgres" {
  name                 = local.postgres_subnet_name
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.postgres_subnet_cidr]

  private_endpoint_network_policies = "Disabled"

  delegation {
    name = "postgres-flexible-server"

    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

# --------------------------------------------------------------------------- #
# Private DNS zone for PostgreSQL Flexible Server private access.
#
# COST: $0.50/mo for the zone.
#
# With VNet integration the server has NO public endpoint. Its FQDN resolves
# only through this zone, and only from VNets linked to it. Linking the cluster
# VNet is what lets in-cluster pods resolve
#   psql-instanode-prod-eastus.<zone> -> 10.60.4.x
#
# registration_enabled = false: this zone holds exactly one record, created by
# the PostgreSQL resource provider. VMs must not auto-register into it.
# --------------------------------------------------------------------------- #

resource "azurerm_private_dns_zone" "postgres" {
  name                = local.postgres_private_dns_zone_name
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

# NOTE for anyone copying a 4.x example: azurerm 5.0 replaced this resource's
# `private_dns_zone_name` + `resource_group_name` pair with a single
# `private_dns_zone_id`. A 4.x snippet fails validation here.
resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                 = "${local.vnet_name}-postgres-link"
  private_dns_zone_id  = azurerm_private_dns_zone.postgres.id
  virtual_network_id   = azurerm_virtual_network.main.id
  registration_enabled = false
  tags                 = local.common_tags
}
