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
  # Number of LICENSED application nodes. FortiAIGate node-keyed licensing pins
  # every pod to licensed nodes (hostname nodeAffinity), so this should equal
  # the number of app-node licenses you have — extra unlicensed nodes can't run
  # workload. With a single app license, keep this at 1 and rely on
  # app_node_max_pods to fit the full service set on the one node.
  description = "Number of licensed application nodes (must match available app-node licenses)"
  type        = number
  default     = 1

  validation {
    condition     = var.app_node_count >= 1
    error_message = "app_node_count must be at least 1."
  }
}

variable "app_node_max_pods" {
  # Azure CNI defaults to 30 pods/node. The full FortiAIGate service set plus
  # system daemonsets exceeds that, and node-keyed licensing forces them all
  # onto the single licensed app node — so the cap must be raised. Set at node
  # pool creation (ForceNew). Classic Azure CNI draws one subnet IP per pod, so
  # max_pods * max nodes must fit in aks_subnet_cidr (/20 = 4096, ample).
  description = "Max pods per application node (Azure CNI default 30 is too low for the full service set on one licensed node)"
  type        = number
  default     = 110
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
  # The GPU must satisfy BOTH: (1) TensorRT 10 in the Triton image needs SM 75+
  # (Turing or newer) — rules out the V100/NCsv3; and (2) the FortiAIGate 8.0.0
  # spec requires a supported model (NVIDIA L4/A10/A100) with >=24 GB VRAM —
  # which rules out the 16 GB T4. On Azure that intersection is the A10
  # (NV36ads_A10_v5, 24 GB) or A100. A10 matches the A10G the EKS stack runs.
  # See docs/gpu-triton-compatibility.md.
  description = "Azure VM size for the GPU node pool. Must be a Fortinet-supported GPU (A10/A100; L4 unavailable on Azure) with >=24 GB VRAM AND SM 75+. Default Standard_NV36ads_A10_v5 (A10, 24 GB). NOTE: A10/A100 families default to 0 quota — request a quota increase first (see docs/gpu-triton-compatibility.md)."
  type        = string
  default     = "Standard_NV36ads_A10_v5"
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

variable "acr_id" {
  description = "Resource ID of the Azure Container Registry holding the FortiAIGate images. When set, the AKS kubelet identity is granted AcrPull on it so nodes can pull images. Leave empty when the ACR is managed elsewhere (the grant must then exist outside this stack). Find it with: az acr show -n <name> --query id -o tsv"
  type        = string
  default     = ""
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

variable "db_storage_class" {
  description = "StorageClass for the bundled PostgreSQL and Redis PVCs. Must be a block (Azure Disk, RWO) class — PostgreSQL cannot initialize its data dir on the shared Azure Files (SMB) class. 'managed-csi' (Standard SSD) ships with AKS; use 'managed-csi-premium' for Premium SSD."
  type        = string
  default     = "managed-csi"
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

variable "helm_timeout" {
  # The helm provider wraps the release install/upgrade in a context with this
  # deadline (seconds). On a FIRST apply the nodes pull ~15 app images + Triton
  # fresh from ACR, which can exceed the old 1200s and surface as "context
  # deadline exceeded" — a re-apply then succeeds because the images are cached.
  # Raised default gives first-pull headroom; bump higher for slow/distant ACRs.
  # NOTE: this does not help when the hang is the licensing 503 on `core` (a
  # stuck "In Use" seat) — that's a hard block a longer timeout won't clear.
  description = "Seconds the helm provider waits for the fortiaigate release to become ready before erroring with 'context deadline exceeded'"
  type        = number
  default     = 2400
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
  description = "Deploy as an internal (private) service. Adds AGIC's private-IP annotation; the Application Gateway must also have a private frontend IP. For public DNS, keep false."
  type        = bool
  default     = false
}

# ----------------------------------------------------------------------------
# Let's Encrypt / cert-manager (optional, default off)
# ----------------------------------------------------------------------------

variable "letsencrypt_enabled" {
  description = "Install cert-manager and issue a browser-trusted Let's Encrypt certificate into fortiaigate-tls-secret via ACME DNS-01 against Azure DNS (workload-identity auth). When true, cert-manager owns the TLS secret instead of the self-signed cert in tls.tf, which also makes AGIC trust the HTTPS backend (the well-known CA chain) and serve a trusted frontend cert. Requires an existing public Azure DNS zone and ingress_host set."
  type        = bool
  default     = false
}

variable "letsencrypt_environment" {
  description = "Which ACME endpoint to use. 'staging' (default) has generous rate limits for validating the pipeline but its root is untrusted (browser still warns); flip to 'production' for a trusted cert. Changing this rolls the app pods to pick up the re-issued cert."
  type        = string
  default     = "staging"

  validation {
    condition     = contains(["staging", "production"], var.letsencrypt_environment)
    error_message = "letsencrypt_environment must be either 'staging' or 'production'."
  }
}

variable "acme_email" {
  description = "Email used to register the ACME (Let's Encrypt) account. Required when letsencrypt_enabled = true."
  type        = string
  default     = ""
}

variable "dns_zone_name" {
  description = "Name of the existing public Azure DNS zone cert-manager writes the _acme-challenge TXT records into (e.g. 'example.com'). Required when letsencrypt_enabled = true."
  type        = string
  default     = ""
}

variable "dns_zone_resource_group" {
  description = "Resource group containing the Azure DNS zone (var.dns_zone_name). May differ from the cluster RG (e.g. an App Service Domains zone). The Terraform principal needs role-assignment write on this scope to grant cert-manager DNS Zone Contributor. Required when letsencrypt_enabled = true."
  type        = string
  default     = ""
}

variable "cert_manager_version" {
  description = "cert-manager Helm chart version to install (e.g. 'v1.16.2'). Use a release that supports Azure workload identity for the DNS-01 solver (v1.11+)."
  type        = string
  default     = "v1.16.2"
}
