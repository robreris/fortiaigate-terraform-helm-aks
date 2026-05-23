# The FortiAIGate chart's shared PVC uses accessModes: [ReadWriteMany], which
# Azure managed disks do not support. Azure Files (via the built-in
# azurefile-csi driver) provides RWX access and is the standard solution on
# AKS. This file sets up the storage account, grants the AKS kubelet identity
# access, and creates the StorageClass that the Helm chart references.

resource "random_string" "storage_suffix" {
  length  = 8
  upper   = false
  special = false
  numeric = true
}

# Storage account name must be globally unique, 3-24 lowercase alphanumerics.
# Trim and append a random suffix to stay within the limit even if cluster_name
# is long.
locals {
  storage_account_name = substr(
    "${replace(lower(var.cluster_name), "/[^a-z0-9]/", "")}${random_string.storage_suffix.result}",
    0, 24
  )
}

resource "azurerm_storage_account" "fortiaigate" {
  name                     = local.storage_account_name
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_tier             = var.storage_account_tier
  account_kind             = var.storage_account_kind
  account_replication_type = "LRS"

  # The azurefile-csi driver authenticates to the storage account using the
  # storage account key by default. Allow shared-key access so the driver can
  # mount shares without Azure AD configuration.
  shared_access_key_enabled = true

  # The chart's shared PVC needs SMB-protocol Azure Files. Enable large file
  # share support so the share can exceed 5 TiB on Premium tier.
  large_file_share_enabled = true

  tags = {
    Name = var.cluster_name
  }
}

# Grant the AKS kubelet identity (the identity nodes use to call Azure APIs)
# permission to manage and mount file shares in this storage account. Without
# this, dynamic provisioning by azurefile-csi will fail with AuthorizationFailed.
resource "azurerm_role_assignment" "kubelet_storage_contributor" {
  scope                = azurerm_storage_account.fortiaigate.id
  role_definition_name = "Storage Account Contributor"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

resource "azurerm_role_assignment" "kubelet_smb_share_contributor" {
  scope                = azurerm_storage_account.fortiaigate.id
  role_definition_name = "Storage File Data SMB Share Contributor"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

# StorageClass used by the FortiAIGate Helm chart (storage.storageClass = "azurefile-fortiaigate").
# Pins dynamic provisioning to the storage account above so all PVCs land in
# the same account — equivalent to the EKS pattern of one EFS filesystem
# backing every chart PVC.
resource "kubernetes_storage_class" "azurefile" {
  metadata {
    name = "azurefile-fortiaigate"
  }

  storage_provisioner    = "file.csi.azure.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = true

  parameters = {
    skuName            = "Premium_LRS"
    storageAccount     = azurerm_storage_account.fortiaigate.name
    resourceGroup      = azurerm_resource_group.this.name
    # Use SMB protocol (default). For NFSv4.1, set protocol = "nfs" and ensure
    # account_kind = "FileStorage" + a private endpoint or service endpoint.
    protocol = "smb"
  }

  mount_options = [
    "dir_mode=0777",
    "file_mode=0777",
    "uid=1001",
    "gid=1001",
    "mfsymlinks",
    "cache=strict",
    "nosharesock",
    "actimeo=30",
  ]

  depends_on = [
    azurerm_role_assignment.kubelet_storage_contributor,
    azurerm_role_assignment.kubelet_smb_share_contributor,
  ]
}
