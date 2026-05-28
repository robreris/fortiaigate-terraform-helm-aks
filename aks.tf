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
    # Pinned to a fixed node count (min = max = app_node_count). FortiAIGate's
    # node-keyed licensing pins every pod (via a hostname nodeAffinity built from
    # the licensed node names) to licensed nodes only — so an unlicensed extra
    # node is invisible to the workload and autoscaling buys nothing. With one
    # app license, ALL app pods must fit on ONE node, which is why max_pods is
    # raised well above the Azure CNI default of 30 (the full service set +
    # system daemonsets exceeds 30). max_pods is set at creation; classic Azure
    # CNI draws pod IPs from the aks subnet (/20 = 4096 IPs, ample).
    node_count           = var.app_node_count
    min_count            = var.app_node_count
    max_count            = var.app_node_count
    auto_scaling_enabled = true
    max_pods             = var.app_node_max_pods
    vnet_subnet_id       = azurerm_subnet.aks.id
    os_disk_size_gb      = var.app_node_disk_size_gb
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

  # With auto_scaling_enabled the autoscaler owns the live node_count; azurerm
  # rejects any attempt to set it ("cannot change node_count when
  # auto_scaling_enabled is set to true"). node_count above is the create-time
  # seed only — ignore drift so applies don't fail once the pool has scaled.
  lifecycle {
    ignore_changes = [default_node_pool[0].node_count]
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

  # Pin the AKS-managed NVIDIA driver install. azurerm records this as "Install"
  # on creation; leaving it unset makes the provider plan it to null, and the
  # field is ForceNew — so omitting it triggers a destructive pool replacement
  # (and a new node name, which re-keys licenses) on the very next apply.
  gpu_driver = "Install"
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

# AcrPull for the kubelet identity so nodes can pull the FortiAIGate images.
# Without it the kubelet has no registry credential, falls back to an anonymous
# token, and ACR returns 401 — every pod stalls in ImagePullBackOff and the
# helm release (and thus terraform apply) hangs waiting for readiness.
#
# Each cluster recreate mints a NEW kubelet identity, so a one-off manual
# `az aks update --attach-acr` does not survive teardown — that's why the issue
# recurs. Codifying the grant here re-establishes it on every apply.
#
# Conditional on var.acr_id: the ACR usually lives in its own resource group /
# Terraform stack, so leave acr_id empty when the grant is owned elsewhere.
# When set, the Terraform principal needs role-assignment write (Owner or
# User Access Administrator) on the ACR's scope.
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  count = var.acr_id != "" ? 1 : 0

  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}
