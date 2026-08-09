###############################################################################
# Resource group.
#
# COST: $0.00/mo - a resource group is a free container.
#
# Everything Terraform owns lives here. AKS additionally creates and owns a
# SECOND resource group (local.node_resource_group_name) holding the VMSS, the
# Standard Load Balancer and the node OS disks. That second group is managed by
# AKS: do not create, edit or delete resources in it by hand, and do not import
# it into this state.
###############################################################################

resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.common_tags
}
