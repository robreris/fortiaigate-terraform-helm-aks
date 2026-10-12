resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    cluster    = var.cluster_name
    managed-by = "terraform"
  }
}

resource "azurerm_virtual_network" "this" {
  count = local.existing_network ? 0 : 1

  name                = "${var.cluster_name}-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.vnet_cidr]
}

# Subnet for AKS nodes. AGIC requires a dedicated, otherwise-empty subnet for
# the Application Gateway, so node and gateway traffic are isolated.
resource "azurerm_subnet" "aks" {
  count = local.existing_network ? 0 : 1

  name                 = "${var.cluster_name}-aks"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this[0].name
  address_prefixes     = [var.aks_subnet_cidr]
}

# Dedicated subnet for the Application Gateway when AGIC is enabled.
# Always created so subnet IDs are stable across enabling/disabling AGIC.
resource "azurerm_subnet" "appgw" {
  count = local.existing_network ? 0 : 1

  name                 = "${var.cluster_name}-appgw"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this[0].name
  address_prefixes     = [var.appgw_subnet_cidr]
}

# Preserve the state identity of networking created by previous releases.
moved {
  from = azurerm_virtual_network.this
  to   = azurerm_virtual_network.this[0]
}
moved {
  from = azurerm_subnet.aks
  to   = azurerm_subnet.aks[0]
}
moved {
  from = azurerm_subnet.appgw
  to   = azurerm_subnet.appgw[0]
}

locals {
  existing_network  = var.existing_vnet_id != ""
  vnet_parts        = split("/", var.existing_vnet_id)
  aks_subnet_id     = local.existing_network ? var.existing_aks_subnet_id : azurerm_subnet.aks[0].id
  appgw_subnet_id   = local.existing_network ? var.existing_appgw_subnet_id : azurerm_subnet.appgw[0].id
  appgw_subnet_cidr = local.existing_network && var.agic_enabled ? data.azurerm_subnet.appgw[0].address_prefixes[0] : var.appgw_subnet_cidr
}

# Read externally owned networking without importing it into this state.
data "azurerm_virtual_network" "existing" {
  count               = local.existing_network ? 1 : 0
  name                = try(local.vnet_parts[8], "")
  resource_group_name = try(local.vnet_parts[4], "")
  lifecycle {
    postcondition {
      condition     = lower(self.id) == lower(var.existing_vnet_id)
      error_message = "existing_vnet_id must be in the subscription selected by the AzureRM provider."
    }
    postcondition {
      condition     = lower(replace(self.location, " ", "")) == lower(replace(var.location, " ", ""))
      error_message = "The existing VNet and AKS deployment must be in the same Azure region."
    }
  }
}

data "azurerm_subnet" "aks" {
  count                = local.existing_network ? 1 : 0
  name                 = try(split("/", var.existing_aks_subnet_id)[10], "")
  virtual_network_name = data.azurerm_virtual_network.existing[0].name
  resource_group_name  = data.azurerm_virtual_network.existing[0].resource_group_name
}

data "azurerm_subnet" "appgw" {
  count                = local.existing_network && var.agic_enabled ? 1 : 0
  name                 = try(split("/", var.existing_appgw_subnet_id)[10], "")
  virtual_network_name = data.azurerm_virtual_network.existing[0].name
  resource_group_name  = data.azurerm_virtual_network.existing[0].resource_group_name
}

resource "terraform_data" "network_configuration" {
  lifecycle {
    precondition {
      condition = local.existing_network ? (
        var.existing_aks_subnet_id != "" && (!var.agic_enabled || var.existing_appgw_subnet_id != "")
      ) : (var.existing_aks_subnet_id == "" && var.existing_appgw_subnet_id == "")
      error_message = "Supply existing_vnet_id and existing_aks_subnet_id together, plus existing_appgw_subnet_id when AGIC is enabled."
    }
    precondition {
      condition = !local.existing_network || (
        startswith(lower(var.existing_aks_subnet_id), "${lower(var.existing_vnet_id)}/subnets/") &&
        (var.existing_appgw_subnet_id == "" || startswith(lower(var.existing_appgw_subnet_id), "${lower(var.existing_vnet_id)}/subnets/"))
      )
      error_message = "Existing AKS and Application Gateway subnets must belong to existing_vnet_id."
    }
    precondition {
      condition     = !local.existing_network || !var.agic_enabled || lower(var.existing_aks_subnet_id) != lower(var.existing_appgw_subnet_id)
      error_message = "Application Gateway requires a separate subnet from AKS."
    }
  }
}

# Pre-create the control-plane identity so external subnet access can be granted
# before AKS creation. The default managed-network identity stays unchanged.
resource "azurerm_user_assigned_identity" "aks_network" {
  count               = local.existing_network ? 1 : 0
  name                = "${var.cluster_name}-network"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_role_assignment" "aks_subnet_network_contributor" {
  count                            = local.existing_network ? 1 : 0
  scope                            = local.aks_subnet_id
  role_definition_name             = "Network Contributor"
  principal_id                     = azurerm_user_assigned_identity.aks_network[0].principal_id
  skip_service_principal_aad_check = true
}
