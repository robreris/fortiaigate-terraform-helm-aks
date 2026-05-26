variable "location" {
  description = "Azure region to deploy into"
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Resource group that will contain the AKS cluster and all dependent resources"
  type        = string
  default     = "fortiaigate"
}

variable "cluster_name" {
  description = "AKS cluster name"
  type        = string
  default     = "fortiaigate"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the AKS cluster. Azure aggressively deprecates older minors per region — verify with `az aks get-versions --location <region> -o table` before pinning."
  type        = string
  default     = "1.35"
}

variable "app_node_vm_size" {
  description = "Azure VM size for the application node pool"
  type        = string
  default     = "Standard_D16s_v5"
}

variable "app_node_count" {
  description = "Number of application nodes"
  type        = number
  default     = 2

  validation {
    condition     = var.app_node_count >= 1
    error_message = "app_node_count must be at least 1."
  }
}

variable "app_node_disk_size_gb" {
  description = "OS disk size (GB) for application nodes"
  type        = number
  default     = 250
}

variable "gpu_enabled" {
  description = "Add a GPU node pool for Triton inference. When false, triton is disabled and all workloads run CPU-only."
  type        = bool
  default     = false
}

variable "gpu_node_vm_size" {
  description = "Azure VM size for the GPU node pool. NCsv3 series provides V100 GPUs suitable for Triton."
  type        = string
  default     = "Standard_NC6s_v3"
}

variable "gpu_node_disk_size_gb" {
  description = "OS disk size (GB) for GPU nodes"
  type        = number
  default     = 250
}

variable "image_repository" {
  description = "Container registry prefix for FortiAIGate images (e.g. myregistry.azurecr.io/fortiaigate)"
  type        = string

  validation {
    condition     = length(var.image_repository) > 0
    error_message = "image_repository is required and must point at a registry containing the FortiAIGate images."
  }
}

variable "image_tag" {
  description = "Image tag for all FortiAIGate service images"
  type        = string
  default     = "V8.0.0-build0024"
}

variable "namespace" {
  description = "Kubernetes namespace for the FortiAIGate deployment"
  type        = string
  default     = "fortiaigate"
}

variable "ingress_class" {
  description = "Ingress class name. 'azure-application-gateway' uses AGIC; 'nginx' uses ingress-nginx (which must be installed separately or via web_app_routing)."
  type        = string
  default     = "azure-application-gateway"

  validation {
    condition     = contains(["azure-application-gateway", "nginx", "webapprouting.kubernetes.azure.com"], var.ingress_class)
    error_message = "ingress_class must be one of 'azure-application-gateway', 'nginx', or 'webapprouting.kubernetes.azure.com'."
  }
}

variable "ingress_host" {
  description = "Hostname for the ingress rule. Leave empty to match all hosts."
  type        = string
  default     = ""
}

variable "ingress_annotations" {
  description = "Additional ingress annotations. Keys with dots/slashes are handled correctly via values YAML merge."
  type        = map(string)
  default     = {}
}

variable "agic_enabled" {
  description = "Enable the AKS Application Gateway Ingress Controller addon. Creates an Application Gateway in the appgw subnet when enabled."
  type        = bool
  default     = true
}

variable "appgw_subnet_cidr" {
  description = "CIDR block for the Application Gateway subnet inside the VNet. Must not overlap with aks_subnet_cidr."
  type        = string
  default     = "10.0.64.0/24"
}

variable "vnet_cidr" {
  description = "CIDR block for the VNet that hosts AKS and the Application Gateway"
  type        = string
  default     = "10.0.0.0/16"
}

variable "aks_subnet_cidr" {
  description = "CIDR block for the AKS node subnet inside the VNet"
  type        = string
  default     = "10.0.0.0/20"
}

variable "storage_size" {
  description = "Size of the shared Azure Files-backed PVC"
  type        = string
  default     = "100Gi"

  validation {
    condition     = can(regex("^[0-9]+(Mi|Gi|Ti)$", var.storage_size))
    error_message = "storage_size must be a Kubernetes quantity with a binary suffix (e.g. '100Gi', '500Mi', '1Ti')."
  }
}

variable "storage_account_tier" {
  description = "Storage account tier backing Azure Files. 'Premium' is required for FileStorage kind (low-latency SMB/NFS); 'Standard' works only with StorageV2."
  type        = string
  default     = "Premium"

  validation {
    condition     = contains(["Standard", "Premium"], var.storage_account_tier)
    error_message = "storage_account_tier must be either 'Standard' or 'Premium'."
  }
}

variable "storage_account_kind" {
  description = "Storage account kind. Use 'FileStorage' (Premium) for low-latency Azure Files; 'StorageV2' for Standard tier."
  type        = string
  default     = "FileStorage"

  validation {
    condition     = contains(["FileStorage", "StorageV2"], var.storage_account_kind)
    error_message = "storage_account_kind must be either 'FileStorage' or 'StorageV2'."
  }
}

variable "licenses" {
  description = "Map of AKS node name to local license file path. Node names are available after cluster creation via 'kubectl get nodes'. Example: { \"aks-app-12345678-vmss000000\" = \"/path/to/license.lic\" }"
  type        = map(string)
  default     = {}
}

variable "update_strategy" {
  description = "Deployment update strategy. 'Recreate' avoids GPU deadlock on single-GPU nodes; 'RollingUpdate' for zero-downtime when spare capacity exists."
  type        = string
  default     = "Recreate"

  validation {
    condition     = contains(["Recreate", "RollingUpdate"], var.update_strategy)
    error_message = "update_strategy must be either 'Recreate' or 'RollingUpdate'."
  }
}

variable "extra_values_files" {
  description = "Additional Helm values YAML files to merge (applied left-to-right, later files take precedence)"
  type        = list(string)
  default     = []
}

variable "internal" {
  description = "Deploy as an internal (private) service. Sets the Application Gateway to internal scheme so it is only reachable within the VNet and connected networks."
  type        = bool
  default     = false
}
