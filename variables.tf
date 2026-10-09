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
  description = "Azure VM size for the application pool. Size for application requests and database resources; deployment licenses no longer bind workloads to node names."
  type        = string
  default     = "Standard_D16s_v5"
}

variable "app_node_count" {
  description = "Number of application nodes (independent of deployment licensing)"
  type        = number
  default     = 1

  validation {
    condition     = var.app_node_count >= 1 && floor(var.app_node_count) == var.app_node_count
    error_message = "app_node_count must be a positive integer."
  }
}

variable "app_node_max_pods" {
  description = "Max pods per application node; account for application/system pods and Azure CNI subnet capacity"
  type        = number
  default     = 110
}

variable "app_node_disk_size_gb" {
  description = "OS disk size (GB) for application nodes"
  type        = number
  default     = 250
}

variable "gpu_enabled" {
  description = "Add a GPU pool for Triton and vLLM. When false, Triton still renders without GPU allocation and vLLM is disabled; POLICY detectors require vLLM and fail closed without it. CPU capabilities need live qualification."
  type        = bool
  default     = false
}

variable "gpu_node_vm_size" {
  # The GPU must satisfy BOTH: (1) TensorRT 10 in the Triton image needs SM 75+
  # (Turing or newer) — rules out the V100/NCsv3; and (2) the FortiAIGate
  # deployment spec requires a supported model (NVIDIA L4/A10/A100) with >=24 GB VRAM —
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

variable "gpu_node_count" {
  description = "Fixed GPU pool size. Dedicated Triton/vLLM mode needs enough cards for both engines (normally at least two one-GPU nodes)."
  type        = number
  default     = 1

  validation {
    condition     = var.gpu_node_count >= 1 && floor(var.gpu_node_count) == var.gpu_node_count
    error_message = "gpu_node_count must be a positive integer."
  }
}

variable "vllm_gpu_attach" {
  description = "Explicit GPU topology: shared runs Triton/vLLM in one pod; dedicated gives each engine its own GPU allocation. Shared mode requires live AKS NVIDIA runtime qualification."
  type        = string
  default     = "shared"

  validation {
    condition     = contains(["shared", "dedicated"], var.vllm_gpu_attach)
    error_message = "vllm_gpu_attach must be shared or dedicated."
  }
}

variable "vllm_image_tag" {
  description = "Tag for the vLLM server and GPU-probe image. Qualify changes together with Triton and faig-models."
  type        = string
  default     = "0.28.0-rpt-s1"
}

variable "image_repository" {
  description = "Container registry prefix for FortiAIGate images (e.g. myregistry.azurecr.io/fortiaigate)"
  type        = string

  validation {
    condition     = length(trimspace(var.image_repository)) > 0
    error_message = "image_repository is required and must point at a registry containing the FortiAIGate images."
  }
}

variable "acr_id" {
  description = "Resource ID of the Azure Container Registry holding the FortiAIGate images. When set, the AKS kubelet identity is granted AcrPull on it so nodes can pull images. Leave empty when the ACR is managed elsewhere (the grant must then exist outside this stack). Find it with: az acr show -n <name> --query id -o tsv"
  type        = string
  default     = ""
}

variable "image_tag" {
  description = "Image tag for FortiAIGate application services (api, llm-gateway, webui, logd, license_manager, guardrail, guardrail-scanner); Triton and its model image use separate tags."
  type        = string
  default     = "V8.0.2-build0047"
}

variable "triton_image_tag" {
  description = "Tag for the custom-triton inference server image in CPU/GPU profiles. Must match the image pushed to the registry."
  type        = string
  default     = "25.11-onnx-trt-agt-rpt-s1"
}

variable "triton_models_image_tag" {
  description = "Tag for the combined faig-models carrier used by Triton and vLLM. Must match the image pushed to the registry."
  type        = string
  default     = "0.0.4-s1"
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

# Retained only to reject obsolete tfvars; its validation is its only use.
# tflint-ignore: terraform_unused_declarations
variable "licenses" {
  description = "Deprecated node-keyed license map. Must be empty for build0047; upload a deployment license through the admin API after installation."
  type        = map(string)
  default     = {}

  validation {
    condition     = length(var.licenses) == 0
    error_message = "Build0047 no longer accepts node-keyed license files. Remove licenses from tfvars and upload a deployment license through POST /api/v1/admin/licenses. Existing deployments need a qualified migration."
  }
}

variable "helm_timeout" {
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
  description = "Expose the UI only on a private IP inside the VNet. When true (requires agic_enabled), Terraform creates the Application Gateway itself with a static private frontend (appgw.tf), points the AGIC add-on at it, and annotates the Ingress so every listener binds to the private IP. When false, the add-on creates a public-only gateway. Choose at deploy time; see docs/application-gateway-dns-tls.md."
  type        = bool
  default     = false
}

variable "appgw_private_ip" {
  description = "Static private frontend IP for the Application Gateway when internal = true. Must be an unused address inside appgw_subnet_cidr. Empty = second-to-last address of the subnet (e.g. 10.0.64.254 for 10.0.64.0/24), per Microsoft's guidance to allocate gateway frontends from the top of the subnet."
  type        = string
  default     = ""
}

# ----------------------------------------------------------------------------
# Let's Encrypt / cert-manager (optional, default off)
# ----------------------------------------------------------------------------

variable "tls_certificate_path" {
  description = "Optional PEM serving certificate chain (leaf first, then intermediates) for web/API HTTPS. Requires tls_private_key_path and ingress_host; mutually exclusive with letsencrypt_enabled. Internal services and databases retain generated TLS certificates."
  type        = string
  default     = ""

  validation {
    condition     = var.tls_certificate_path == "" ? true : can(regex("-----BEGIN CERTIFICATE-----", file(var.tls_certificate_path)))
    error_message = "tls_certificate_path must point to a readable PEM certificate chain."
  }
}

variable "tls_private_key_path" {
  description = "Path to the unencrypted PEM private key matching tls_certificate_path. Its contents are stored in Terraform state; protect the state and keep the file outside version control."
  type        = string
  default     = ""

  validation {
    condition     = var.tls_private_key_path == "" ? true : can(regex("-----BEGIN (RSA |EC )?PRIVATE KEY-----", file(var.tls_private_key_path)))
    error_message = "tls_private_key_path must point to a readable, unencrypted PEM private key."
  }
}

variable "tls_ca_certificate_path" {
  description = "Optional PEM root CA certificate for supplied web/API certificates signed by a private CA. Uploaded automatically only to the Terraform-managed private Application Gateway; configure public add-on gateways manually. Omit for a publicly trusted certificate. This is a public certificate, never a CA private key."
  type        = string
  default     = ""

  validation {
    condition     = var.tls_ca_certificate_path == "" ? true : can(regex("-----BEGIN CERTIFICATE-----", file(var.tls_ca_certificate_path)))
    error_message = "tls_ca_certificate_path must point to a readable PEM root CA certificate."
  }
}

variable "letsencrypt_enabled" {
  description = "Install cert-manager and issue a Let's Encrypt web/API certificate via Azure DNS-01. Requires an existing public Azure DNS zone and ingress_host, and is mutually exclusive with tls_certificate_path. Internal services and databases retain generated TLS certificates."
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
