resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version

  # Workload Identity + OIDC issuer let chart service accounts assume Azure
  # identities — the AKS analogue of EKS IRSA. Required by the Azure Files
  # CSI driver (built-in) for managed-identity SAS access, and by AGIC if
  # we later switch from the addon-managed identity to BYOI.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name            = "app"
    vm_size         = var.app_node_vm_size
    node_count      = var.app_node_count
    min_count       = 1
    max_count       = var.app_node_count + 2
    auto_scaling_enabled = true
    vnet_subnet_id  = azurerm_subnet.aks.id
    os_disk_size_gb = var.app_node_disk_size_gb
    node_labels = {
      fortiaigate-role = "app"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    network_policy = "azure"
    service_cidr   = "10.1.0.0/16"
    dns_service_ip = "10.1.0.10"
  }

  # AGIC addon — AKS creates and manages the Application Gateway in the
  # appgw subnet. Toggle off to manage ingress externally (ingress-nginx,
  # web_app_routing addon, BYO controller).
  dynamic "ingress_application_gateway" {
    for_each = var.agic_enabled ? [1] : []
    content {
      gateway_name = "${var.cluster_name}-appgw"
      subnet_id    = azurerm_subnet.appgw.id
    }
  }
}

# GPU node pool — separate resource so it can be added/removed without
# replacing the cluster. Tainted to keep CPU workloads off the (expensive)
# GPU nodes; the chart's gpu_values block (helm.tf) supplies matching
# tolerations to the GPU workloads that should land here.
resource "azurerm_kubernetes_cluster_node_pool" "gpu" {
  count = var.gpu_enabled ? 1 : 0

  name                  = "gpu"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.gpu_node_vm_size
  vnet_subnet_id        = azurerm_subnet.aks.id
  os_disk_size_gb       = var.gpu_node_disk_size_gb
  auto_scaling_enabled  = true
  min_count             = 0
  max_count             = 1
  node_count            = 1

  node_labels = {
    fortiaigate-role = "gpu"
  }

  node_taints = [
    "fortiaigate-gpu=true:NoSchedule",
  ]
}
