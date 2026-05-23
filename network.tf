resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    "kubernetes.io/cluster" = var.cluster_name
  }
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.cluster_name}-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.vnet_cidr]
}

# Subnet for AKS nodes. AGIC requires a dedicated, otherwise-empty subnet for
# the Application Gateway, so node and gateway traffic are isolated.
resource "azurerm_subnet" "aks" {
  name                 = "${var.cluster_name}-aks"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.aks_subnet_cidr]
}

# Dedicated subnet for the Application Gateway when AGIC is enabled.
# Always created so subnet IDs are stable across enabling/disabling AGIC.
resource "azurerm_subnet" "appgw" {
  name                 = "${var.cluster_name}-appgw"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.appgw_subnet_cidr]
}
