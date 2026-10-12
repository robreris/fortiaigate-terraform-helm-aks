# FortiAIGate on Azure AKS — Terraform + Helm

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)
[![Terraform](https://img.shields.io/badge/terraform-%E2%89%A51.5-623CE4.svg)](https://www.terraform.io/)
[![Kubernetes](https://img.shields.io/badge/kubernetes-1.35-326CE5.svg)](https://kubernetes.io/)

Terraform stack that deploys FortiAIGate on Azure AKS.

The local Helm chart is based on the downloaded FortiAIGate 8.0.2/build0047
chart, with AKS-specific ingress, storage, TLS, license, and GPU placement
patches. The default application and Triton image tags match build0047.

## What you get

- A resource group holding the VNet, AKS cluster, Azure Files storage account, and (optionally) the Application Gateway.
- AKS cluster with:
  - An `app` node pool (default 1x `Standard_D16s_v5`, `max_pods` raised to 110) for FortiAIGate application services and the Bitnami PostgreSQL/Redis subcharts. Workloads select the app pool independently of deployment licensing.
  - An optional `gpu` node pool (default 1x `Standard_NV36ads_A10_v5`, an A10) for Triton/vLLM, tainted so only GPU workloads land there. The combined build0047 workload still needs hardware/runtime qualification — see [docs/gpu-triton-compatibility.md](docs/gpu-triton-compatibility.md).
  - OIDC issuer and workload identity enabled (AKS analogue of EKS IRSA).
  - AGIC addon (optional) — AKS provisions and manages a public Application Gateway in a dedicated subnet, or, with `internal = true`, drives a Terraform-managed gateway whose listeners bind to a static private IP.
- A Premium Azure Files storage account, the kubelet identity role assignments needed for dynamic file-share provisioning, and an `azurefile-fortiaigate` StorageClass.
- The `fortiaigate` Helm release, with generated internal TLS, generated/supplied/Let's Encrypt web TLS, and deployment licensing uploaded through the admin API. For public DNS and production TLS, see [docs/application-gateway-dns-tls.md](docs/application-gateway-dns-tls.md).

## Prerequisites

- Terraform `>= 1.5`
- Azure CLI signed in (`az login`) with rights to:
  - Create resource groups, VNets, AKS clusters, role assignments, and storage accounts in the target subscription.
  - Retrieve AKS credentials. Terraform currently authenticates to Kubernetes using the client certificate emitted by AKS; this stack does not configure Entra ID integration.
- A container registry holding the FortiAIGate images (typically an Azure Container Registry — `<name>.azurecr.io`). The AKS kubelet identity must have `AcrPull` on it or every pod stalls in `ImagePullBackOff`. This stack **can** codify that grant: set `acr_id` in your tfvars and the kubelet identity is granted `AcrPull` automatically (the Terraform SP then needs role-assignment write on the ACR's scope). Leave `acr_id` empty if the ACR and its grant are managed in another stack. See [docs/registry-and-images.md](docs/registry-and-images.md) for creating the registry, pushing the images, and the grant.
- **GPU quota (if `gpu_enabled = true`).** The default GPU SKU is an A10 (`Standard_NV36ads_A10_v5`), and the A10/A100 vCPU quota families default to **0** in most regions — request a quota increase (e.g. *Standard NVADSA10v5 Family vCPUs* → 36) in the target region **before** the first apply, or step 1 fails creating the GPU pool. See [docs/gpu-triton-compatibility.md](docs/gpu-triton-compatibility.md).
- One-time per-subscription bootstrap of remote state: a Resource Group, Storage Account, and Container for the Terraform state blob — see [docs/remote-state.md](docs/remote-state.md).
- Service principal with the right roles — see [docs/permissions-preflight.md](docs/permissions-preflight.md) to verify before your first apply.

## Quickstart

```bash
# 1. Copy templates
cp backends/backend.hcl.example backends/dev.hcl       # fill in storage account + container
cp tfvars/dev.tfvars.example     tfvars/dev.tfvars     # fill in image_repository, region, etc.

# 2. Init against the chosen subscription's state container
terraform init -backend-config=backends/dev.hcl -reconfigure

# 3. First-time deploy — TWO STEPS (see below)
terraform apply \
  -target=azurerm_resource_group.this \
  -target=azurerm_virtual_network.this \
  -target=azurerm_subnet.aks \
  -target=azurerm_subnet.appgw \
  -target=azurerm_kubernetes_cluster.this \
  -target=azurerm_kubernetes_cluster_node_pool.gpu \
  -target=azurerm_role_assignment.agic_appgw_subnet_network_contributor \
  -target=azurerm_role_assignment.kubelet_acr_pull \
  -target=azurerm_role_assignment.agic_appgw_contributor \
  -target=azurerm_role_assignment.agic_rg_reader \
  -var-file=tfvars/dev.tfvars

# (the gpu pool, AGIC subnet grant, and AcrPull grant are count-gated on
#  gpu_enabled, agic_enabled, and acr_id respectively; the two AGIC gateway
#  grants exist only when internal = true — each resolves to zero resources
#  when its toggle is off, so they're safe to leave in. The AGIC grants go in
#  step 1 because the addon starts programming the Application Gateway as soon
#  as the cluster exists. In internal mode the Terraform-managed gateway is
#  pulled into step 1 automatically, since the cluster references it.)

# Infrastructure is ready for the full application apply.
```

Before the full apply, make sure the AKS kubelet identity has `AcrPull`
on the registry. If you set `acr_id`, Terraform manages that grant. If
you leave `acr_id` empty, grant it manually:
[Later: grant `AcrPull` once the cluster exists](docs/registry-and-images.md#later-grant-acrpull-once-the-cluster-exists).

```bash
terraform apply -var-file=tfvars/dev.tfvars

# 4. Talk to the cluster
$(terraform output -raw configure_kubectl)
kubectl get pods,pvc,ingress -n fortiaigate
terraform output ingress_address
```

After installation, upload your deployment license through the authenticated
`POST /api/v1/admin/licenses` endpoint using the release's documented request
format. License validity and GPU coverage require functional checks. See
[operations](docs/operations.md#deployment-licensing).

For the Azure equivalent of the AWS `ALB + Route 53 + ACM` flow, use
Application Gateway + Azure DNS (or your DNS provider) + a trusted TLS
certificate. See [Application Gateway, DNS, and TLS](docs/application-gateway-dns-tls.md).
To deploy with your own certificate and private key, see [Supplied TLS certificates](docs/tls-supplied.md).

### Why two steps?

The `helm` and `kubernetes` providers in `providers.tf` read connection details from `azurerm_kubernetes_cluster.this.kube_config`. On a clean apply the cluster doesn't exist yet, so any single-shot run fails when Terraform tries to plan the helm/kubernetes resources. Bootstrap the infra first, then apply the rest. Subsequent applies don't need targeting.

Bootstrap the GPU pool with the infrastructure when enabled so inference can
schedule during the full apply. Build0047 does not require node-name discovery
or per-node license files between these steps.

## Existing networking

To deploy into an externally managed VNet and subnets, supply the existing
network resource IDs. See [Existing VNet and subnets](docs/existing-network.md)
for inputs, permissions, network prerequisites, and bootstrap steps.

## Per-subscription layout

State, backend, and variables are partitioned by Azure subscription:

| Path | Purpose | Tracked in git? |
|------|---------|-----------------|
| `backends/<name>.hcl.example` | Template for a backend config | Yes |
| `backends/<name>.hcl` | Actual backend config (storage account, container, key) | No (gitignored) |
| `tfvars/<name>.tfvars.example` | Template for a tfvars file | Yes |
| `tfvars/<name>.tfvars` | Actual variable values (image repo, ingress host, GPU topology) | No (gitignored) |

To switch subscriptions, set the AZ context (`az account set --subscription <id>`), then re-init with the new backend: `terraform init -backend-config=backends/<new>.hcl -reconfigure`.

## Common variables

| Variable | Default | Notes |
|----------|---------|-------|
| `location` | `eastus` | Azure region. Must have quota for the chosen VM sizes — A10/A100 GPU families are request-only (default 0) in most regions. |
| `cluster_name` | `fortiaigate` | Used as the AKS name, DNS prefix, and (after stripping) the storage account name prefix. |
| `app_node_count` | `1` | Fixed application pool size, independent of deployment licenses. |
| `app_node_max_pods` | `110` | Per-node pod cap. Account for service/system pods and Azure CNI subnet capacity. |
| `gpu_enabled` | `false` | Adds the GPU pool and device plugin. Without it, vLLM is disabled and POLICY detectors fail closed; CPU-only capabilities are unqualified. |
| `gpu_node_vm_size` | `Standard_NV36ads_A10_v5` | A10 (24 GB, SM 86). Must be a Fortinet-supported GPU with ≥24 GB VRAM and SM 75+; the V100 fails. |
| `acr_id` | `""` | Set to the ACR resource ID to codify the kubelet `AcrPull` grant; leave empty if managed elsewhere. |
| `image_tag` | `V8.0.2-build0047` | Application image tag; does not set Triton image tags. |
| `triton_image_tag` | `25.11-onnx-trt-agt-rpt-s1` | `custom-triton` tag when GPU is enabled. |
| `triton_models_image_tag` | `0.0.4-s1` | `faig-models` tag shared by Triton and vLLM. |
| `db_storage_class` | `managed-csi` | Block (RWO) StorageClass for PostgreSQL/Redis — they cannot run on the shared Azure Files (SMB) class. |
| `agic_enabled` | `true` | Disable to use ingress-nginx or web_app_routing instead. |
| `ingress_class` | `azure-application-gateway` | Must match the installed controller. |
| `internal` | `false` | False: the AGIC add-on creates a public-only gateway; point DNS at its public IP. True: Terraform creates the gateway with a static private frontend, points AGIC at it, and binds all listeners to the private IP (VNet/VPN access only). Decide before the first deploy — see `docs/application-gateway-dns-tls.md`. |
| `appgw_private_ip` | `""` | Private frontend IP when `internal = true`. Empty = second-to-last address of `appgw_subnet_cidr` (e.g. `10.0.64.254`). |
| `ingress_host` | `""` | Hostname for the ingress rule, e.g. `fortiaigate.example.com`. Set this before creating DNS/TLS for a public UI. |
| `image_repository` | *(required)* | e.g. `myregistry.azurecr.io/fortiaigate`. |
| `vllm_image_tag` | `0.28.0-rpt-s1` | vLLM serving and GPU-probe image. |
| `vllm_gpu_attach` | `shared` | Explicit shared/dedicated GPU layout; shared runtime needs live AKS qualification. |
| `gpu_node_count` | `1` | Fixed GPU pool size; dedicated mode normally needs at least two one-GPU nodes. |

Full list in `variables.tf`.

The Terraform defaults and tfvars examples select the build0047 image set.
Set all four image tag variables explicitly when moving to a later build.
This repository does not bundle images; the
[registry guide](docs/registry-and-images.md) records the names and tags
verified from the supplied build0047 archives.

The build0047 port targets fresh installations. It replaces core/scanners with
LLM gateway/guardrail services and routes `/ai` to the gateway, `/api/` to API,
and `/ui` plus `/` to webui. It includes vLLM and deployment licensing.
Existing deployment upgrades, database migration, and licensing conversion are
not qualified; use [the compatibility audit](docs/build0047-compatibility.md).
Offline tests do not establish live AKS or model compatibility.

Terraform owns the local `fortiaigate` Helm release. `helm.tf` passes the
variables above into chart values; its `set` blocks take precedence over
`extra_values_files`. Terraform also overrides extra values for GPU placement,
Azure Disk database storage, AGIC annotations, TLS, stable application secrets, and app/GPU pool placement.
Use `extra_values_files` for chart settings without a dedicated Terraform
variable, such as per-service resource requests or replica counts. Changing the
chart's defaults alone does not change values already supplied by Terraform.

## Testing and release readiness

Run the local checks in [CONTRIBUTING.md](CONTRIBUTING.md), then follow the
[deployment test checklist](docs/testing.md) in a dedicated Azure subscription.
The [roadmap](ROADMAP.md) records remaining production gaps; the production
tfvars example is a starting configuration, not a high-availability guarantee.

## Documentation

- [8.0.2 build0047 compatibility audit](docs/build0047-compatibility.md) — planned AKS port, verified image tags, and validation gaps.
- [Operations and upgrades](docs/operations.md) — credential adoption, licensing, storage constraints, and rollouts.
- [Supplied TLS certificates](docs/tls-supplied.md) — use your own certificate while retaining internal database TLS.
- [Application Gateway, DNS, and TLS](docs/application-gateway-dns-tls.md) — Azure equivalent of ALB + Route 53 + ACM.
- [Container registry and image upload](docs/registry-and-images.md) — ACR, image push, and `AcrPull`.
- [GPU and Triton compatibility](docs/gpu-triton-compatibility.md) — supported Azure GPU SKUs and quota.
- [Permissions pre-flight](docs/permissions-preflight.md) — Azure RBAC and provider checks before apply.
- [Remote state](docs/remote-state.md) — Azure Storage backend bootstrap.

## Teardown

Order matters — Helm finalizers (PVCs, the Application Gateway's listener bindings) can block `terraform destroy` if released out of order:

```bash
helm -n fortiaigate uninstall fortiaigate
helm -n kube-system uninstall nvidia-device-plugin     # if gpu_enabled

# Wait for PVCs/ingresses to clear, then:
terraform destroy -var-file=tfvars/dev.tfvars
```

Only releases with finalizer risk are uninstalled by hand above. The other Terraform-managed Helm releases — cert-manager and the Stakater Reloader (both only present when `letsencrypt_enabled`) — have no PVCs, load balancers, or finalizers, so `terraform destroy` removes them cleanly with no manual `helm uninstall` step.

The Azure Files storage account is part of the resource group and goes away with `destroy`. The PVs have `Retain` set, so the underlying shares survive until the storage account itself is dropped; back them up first if you need their contents.

## License

Apache 2.0 — see `LICENSE`.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5 |
| <a name="requirement_azuread"></a> [azuread](#requirement\_azuread) | ~> 3.0 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 4.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 2.15 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.35 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.6 |
| <a name="requirement_tls"></a> [tls](#requirement\_tls) | ~> 4.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | ~> 4.0 |
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 2.15 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.35 |
| <a name="provider_random"></a> [random](#provider\_random) | ~> 3.6 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |
| <a name="provider_tls"></a> [tls](#provider\_tls) | ~> 4.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [azurerm_application_gateway.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_gateway) | resource |
| [azurerm_federated_identity_credential.cert_manager](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/federated_identity_credential) | resource |
| [azurerm_kubernetes_cluster.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster) | resource |
| [azurerm_kubernetes_cluster_node_pool.gpu](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster_node_pool) | resource |
| [azurerm_public_ip.appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/public_ip) | resource |
| [azurerm_resource_group.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_role_assignment.agic_appgw_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.agic_appgw_subnet_network_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.agic_rg_reader](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.aks_subnet_network_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.cert_manager_dns](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.cluster_storage_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.kubelet_acr_pull](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.kubelet_smb_share_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.kubelet_storage_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_storage_account.fortiaigate](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_account) | resource |
| [azurerm_subnet.aks](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_user_assigned_identity.aks_network](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_user_assigned_identity.cert_manager](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_virtual_network.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network) | resource |
| [helm_release.cert_manager](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.cert_manager_issuer](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.fortiaigate](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.nvidia_device_plugin](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.reloader](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubernetes_namespace.fortiaigate](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) | resource |
| [kubernetes_secret.application](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_secret.internal_tls](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_secret.postgresql](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_secret.redis](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_secret.tls](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_storage_class.azurefile](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/storage_class) | resource |
| [random_password.application_master_key](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_password.csrf](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_password.postgresql_admin](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_password.postgresql_user](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_password.redis](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_string.storage_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string) | resource |
| [terraform_data.network_configuration](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.tls_configuration](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [tls_cert_request.fortiaigate](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/cert_request) | resource |
| [tls_locally_signed_cert.fortiaigate](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/locally_signed_cert) | resource |
| [tls_private_key.ca](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key) | resource |
| [tls_private_key.fortiaigate](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key) | resource |
| [tls_self_signed_cert.ca](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/self_signed_cert) | resource |
| [azurerm_client_config.current](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/client_config) | data source |
| [azurerm_dns_zone.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/dns_zone) | data source |
| [azurerm_subnet.aks](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/subnet) | data source |
| [azurerm_subnet.appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/subnet) | data source |
| [azurerm_virtual_network.existing](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/virtual_network) | data source |
| [kubernetes_ingress_v1.fortiaigate](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/data-sources/ingress_v1) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_image_repository"></a> [image\_repository](#input\_image\_repository) | Container registry prefix for FortiAIGate images (e.g. myregistry.azurecr.io/fortiaigate) | `string` | n/a | yes |
| <a name="input_acme_email"></a> [acme\_email](#input\_acme\_email) | Email used to register the ACME (Let's Encrypt) account. Required when letsencrypt\_enabled = true. | `string` | `""` | no |
| <a name="input_acr_id"></a> [acr\_id](#input\_acr\_id) | Resource ID of the Azure Container Registry holding the FortiAIGate images. When set, the AKS kubelet identity is granted AcrPull on it so nodes can pull images. Leave empty when the ACR is managed elsewhere (the grant must then exist outside this stack). Find it with: az acr show -n <name> --query id -o tsv | `string` | `""` | no |
| <a name="input_agic_enabled"></a> [agic\_enabled](#input\_agic\_enabled) | Enable the AKS Application Gateway Ingress Controller addon. Creates an Application Gateway in the appgw subnet when enabled. | `bool` | `true` | no |
| <a name="input_aks_subnet_cidr"></a> [aks\_subnet\_cidr](#input\_aks\_subnet\_cidr) | CIDR block for the AKS node subnet inside the VNet | `string` | `"10.0.0.0/20"` | no |
| <a name="input_app_node_count"></a> [app\_node\_count](#input\_app\_node\_count) | Number of application nodes (independent of deployment licensing) | `number` | `1` | no |
| <a name="input_app_node_disk_size_gb"></a> [app\_node\_disk\_size\_gb](#input\_app\_node\_disk\_size\_gb) | OS disk size (GB) for application nodes | `number` | `250` | no |
| <a name="input_app_node_max_pods"></a> [app\_node\_max\_pods](#input\_app\_node\_max\_pods) | Max pods per application node; account for application/system pods and Azure CNI subnet capacity | `number` | `110` | no |
| <a name="input_app_node_vm_size"></a> [app\_node\_vm\_size](#input\_app\_node\_vm\_size) | Azure VM size for the application pool. Size for application requests and database resources; deployment licenses no longer bind workloads to node names. | `string` | `"Standard_D16s_v5"` | no |
| <a name="input_appgw_private_ip"></a> [appgw\_private\_ip](#input\_appgw\_private\_ip) | Static private frontend IP for the Application Gateway when internal = true. Must be an unused address inside appgw\_subnet\_cidr. Empty = second-to-last address of the subnet (e.g. 10.0.64.254 for 10.0.64.0/24), per Microsoft's guidance to allocate gateway frontends from the top of the subnet. | `string` | `""` | no |
| <a name="input_appgw_subnet_cidr"></a> [appgw\_subnet\_cidr](#input\_appgw\_subnet\_cidr) | CIDR block for the Application Gateway subnet inside the VNet. Must not overlap with aks\_subnet\_cidr. | `string` | `"10.0.64.0/24"` | no |
| <a name="input_cert_manager_version"></a> [cert\_manager\_version](#input\_cert\_manager\_version) | cert-manager Helm chart version to install (e.g. 'v1.16.2'). Use a release that supports Azure workload identity for the DNS-01 solver (v1.11+). | `string` | `"v1.16.2"` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | AKS cluster name | `string` | `"fortiaigate"` | no |
| <a name="input_db_storage_class"></a> [db\_storage\_class](#input\_db\_storage\_class) | StorageClass for the bundled PostgreSQL and Redis PVCs. Must be a block (Azure Disk, RWO) class — PostgreSQL cannot initialize its data dir on the shared Azure Files (SMB) class. 'managed-csi' (Standard SSD) ships with AKS; use 'managed-csi-premium' for Premium SSD. | `string` | `"managed-csi"` | no |
| <a name="input_dns_service_ip"></a> [dns\_service\_ip](#input\_dns\_service\_ip) | Kubernetes DNS service IPv4 address inside service\_cidr. | `string` | `"10.1.0.10"` | no |
| <a name="input_dns_zone_name"></a> [dns\_zone\_name](#input\_dns\_zone\_name) | Name of the existing public Azure DNS zone cert-manager writes the \_acme-challenge TXT records into (e.g. 'example.com'). Required when letsencrypt\_enabled = true. | `string` | `""` | no |
| <a name="input_dns_zone_resource_group"></a> [dns\_zone\_resource\_group](#input\_dns\_zone\_resource\_group) | Resource group containing the Azure DNS zone (var.dns\_zone\_name). May differ from the cluster RG (e.g. an App Service Domains zone). The Terraform principal needs role-assignment write on this scope to grant cert-manager DNS Zone Contributor. Required when letsencrypt\_enabled = true. | `string` | `""` | no |
| <a name="input_existing_aks_subnet_id"></a> [existing\_aks\_subnet\_id](#input\_existing\_aks\_subnet\_id) | Existing aks subnet resource ID. Set all existing network IDs together (gateway subnet optional when AGIC is disabled). External networking remains outside this stack's ownership. | `string` | `""` | no |
| <a name="input_existing_appgw_subnet_id"></a> [existing\_appgw\_subnet\_id](#input\_existing\_appgw\_subnet\_id) | Existing appgw subnet resource ID. Set all existing network IDs together (gateway subnet optional when AGIC is disabled). External networking remains outside this stack's ownership. | `string` | `""` | no |
| <a name="input_existing_vnet_id"></a> [existing\_vnet\_id](#input\_existing\_vnet\_id) | Existing vnet resource ID. Set all existing network IDs together (gateway subnet optional when AGIC is disabled). External networking remains outside this stack's ownership. | `string` | `""` | no |
| <a name="input_extra_values_files"></a> [extra\_values\_files](#input\_extra\_values\_files) | Additional Helm values YAML files to merge (applied left-to-right, later files take precedence) | `list(string)` | `[]` | no |
| <a name="input_gpu_enabled"></a> [gpu\_enabled](#input\_gpu\_enabled) | Add a GPU pool for Triton and vLLM. When false, Triton still renders without GPU allocation and vLLM is disabled; POLICY detectors require vLLM and fail closed without it. CPU capabilities need live qualification. | `bool` | `false` | no |
| <a name="input_gpu_node_count"></a> [gpu\_node\_count](#input\_gpu\_node\_count) | Fixed GPU pool size. Dedicated Triton/vLLM mode needs enough cards for both engines (normally at least two one-GPU nodes). | `number` | `1` | no |
| <a name="input_gpu_node_disk_size_gb"></a> [gpu\_node\_disk\_size\_gb](#input\_gpu\_node\_disk\_size\_gb) | OS disk size (GB) for GPU nodes | `number` | `250` | no |
| <a name="input_gpu_node_vm_size"></a> [gpu\_node\_vm\_size](#input\_gpu\_node\_vm\_size) | Azure VM size for the GPU node pool. Must be a Fortinet-supported GPU (A10/A100; L4 unavailable on Azure) with >=24 GB VRAM AND SM 75+. Default Standard\_NV36ads\_A10\_v5 (A10, 24 GB). NOTE: A10/A100 families default to 0 quota — request a quota increase first (see docs/gpu-triton-compatibility.md). | `string` | `"Standard_NV36ads_A10_v5"` | no |
| <a name="input_helm_timeout"></a> [helm\_timeout](#input\_helm\_timeout) | Seconds the helm provider waits for the fortiaigate release to become ready before erroring with 'context deadline exceeded' | `number` | `2400` | no |
| <a name="input_image_tag"></a> [image\_tag](#input\_image\_tag) | Image tag for FortiAIGate application services (api, llm-gateway, webui, logd, license\_manager, guardrail, guardrail-scanner); Triton and its model image use separate tags. | `string` | `"V8.0.2-build0047"` | no |
| <a name="input_ingress_annotations"></a> [ingress\_annotations](#input\_ingress\_annotations) | Additional ingress annotations. Keys with dots/slashes are handled correctly via values YAML merge. | `map(string)` | `{}` | no |
| <a name="input_ingress_class"></a> [ingress\_class](#input\_ingress\_class) | Ingress class name. 'azure-application-gateway' uses AGIC; 'nginx' uses ingress-nginx (which must be installed separately or via web\_app\_routing). | `string` | `"azure-application-gateway"` | no |
| <a name="input_ingress_host"></a> [ingress\_host](#input\_ingress\_host) | Hostname for the ingress rule. Leave empty to match all hosts. | `string` | `""` | no |
| <a name="input_internal"></a> [internal](#input\_internal) | Expose the UI only on a private IP inside the VNet. When true (requires agic\_enabled), Terraform creates the Application Gateway itself with a static private frontend (appgw.tf), points the AGIC add-on at it, and annotates the Ingress so every listener binds to the private IP. When false, the add-on creates a public-only gateway. Choose at deploy time; see docs/application-gateway-dns-tls.md. | `bool` | `false` | no |
| <a name="input_kubernetes_version"></a> [kubernetes\_version](#input\_kubernetes\_version) | Kubernetes version for the AKS cluster. Azure aggressively deprecates older minors per region — verify with `az aks get-versions --location <region> -o table` before pinning. | `string` | `"1.35"` | no |
| <a name="input_letsencrypt_enabled"></a> [letsencrypt\_enabled](#input\_letsencrypt\_enabled) | Install cert-manager and issue a Let's Encrypt web/API certificate via Azure DNS-01. Requires an existing public Azure DNS zone and ingress\_host, and is mutually exclusive with tls\_certificate\_path. Internal services and databases retain generated TLS certificates. | `bool` | `false` | no |
| <a name="input_letsencrypt_environment"></a> [letsencrypt\_environment](#input\_letsencrypt\_environment) | Which ACME endpoint to use. 'staging' (default) has generous rate limits for validating the pipeline but its root is untrusted (browser still warns); flip to 'production' for a trusted cert. Changing this rolls the app pods to pick up the re-issued cert. | `string` | `"staging"` | no |
| <a name="input_licenses"></a> [licenses](#input\_licenses) | Deprecated node-keyed license map. Must be empty for build0047; upload a deployment license through the admin API after installation. | `map(string)` | `{}` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region to deploy into | `string` | `"eastus"` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Kubernetes namespace for the FortiAIGate deployment | `string` | `"fortiaigate"` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Resource group that will contain the AKS cluster and all dependent resources | `string` | `"fortiaigate"` | no |
| <a name="input_service_cidr"></a> [service\_cidr](#input\_service\_cidr) | Kubernetes service CIDR; must not overlap the VNet or connected networks. | `string` | `"10.1.0.0/16"` | no |
| <a name="input_storage_account_kind"></a> [storage\_account\_kind](#input\_storage\_account\_kind) | Storage account kind. Use 'FileStorage' (Premium) for low-latency Azure Files; 'StorageV2' for Standard tier. | `string` | `"FileStorage"` | no |
| <a name="input_storage_account_tier"></a> [storage\_account\_tier](#input\_storage\_account\_tier) | Storage account tier backing Azure Files. 'Premium' is required for FileStorage kind (low-latency SMB/NFS); 'Standard' works only with StorageV2. | `string` | `"Premium"` | no |
| <a name="input_storage_size"></a> [storage\_size](#input\_storage\_size) | Size of the shared Azure Files-backed PVC | `string` | `"100Gi"` | no |
| <a name="input_tls_ca_certificate_path"></a> [tls\_ca\_certificate\_path](#input\_tls\_ca\_certificate\_path) | Optional PEM root CA certificate for supplied web/API certificates signed by a private CA. Uploaded automatically only to the Terraform-managed private Application Gateway; configure public add-on gateways manually. Omit for a publicly trusted certificate. This is a public certificate, never a CA private key. | `string` | `""` | no |
| <a name="input_tls_certificate_path"></a> [tls\_certificate\_path](#input\_tls\_certificate\_path) | Optional PEM serving certificate chain (leaf first, then intermediates) for web/API HTTPS. Requires tls\_private\_key\_path and ingress\_host; mutually exclusive with letsencrypt\_enabled. Internal services and databases retain generated TLS certificates. | `string` | `""` | no |
| <a name="input_tls_private_key_path"></a> [tls\_private\_key\_path](#input\_tls\_private\_key\_path) | Path to the unencrypted PEM private key matching tls\_certificate\_path. Its contents are stored in Terraform state; protect the state and keep the file outside version control. | `string` | `""` | no |
| <a name="input_triton_image_tag"></a> [triton\_image\_tag](#input\_triton\_image\_tag) | Tag for the custom-triton inference server image in CPU/GPU profiles. Must match the image pushed to the registry. | `string` | `"25.11-onnx-trt-agt-rpt-s1"` | no |
| <a name="input_triton_models_image_tag"></a> [triton\_models\_image\_tag](#input\_triton\_models\_image\_tag) | Tag for the combined faig-models carrier used by Triton and vLLM. Must match the image pushed to the registry. | `string` | `"0.0.4-s1"` | no |
| <a name="input_update_strategy"></a> [update\_strategy](#input\_update\_strategy) | Deployment update strategy. 'Recreate' avoids GPU deadlock on single-GPU nodes; 'RollingUpdate' for zero-downtime when spare capacity exists. | `string` | `"Recreate"` | no |
| <a name="input_vllm_gpu_attach"></a> [vllm\_gpu\_attach](#input\_vllm\_gpu\_attach) | Explicit GPU topology: shared runs Triton/vLLM in one pod; dedicated gives each engine its own GPU allocation. Shared mode requires live AKS NVIDIA runtime qualification. | `string` | `"shared"` | no |
| <a name="input_vllm_image_tag"></a> [vllm\_image\_tag](#input\_vllm\_image\_tag) | Tag for the vLLM server and GPU-probe image. Qualify changes together with Triton and faig-models. | `string` | `"0.28.0-rpt-s1"` | no |
| <a name="input_vnet_cidr"></a> [vnet\_cidr](#input\_vnet\_cidr) | CIDR block for the VNet that hosts AKS and the Application Gateway | `string` | `"10.0.0.0/16"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_appgw_private_ip"></a> [appgw\_private\_ip](#output\_appgw\_private\_ip) | Private frontend IP of the Application Gateway when internal = true (point internal DNS for ingress\_host here); null in public mode |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | AKS cluster name |
| <a name="output_configure_kubectl"></a> [configure\_kubectl](#output\_configure\_kubectl) | Run this command to configure kubectl for the new cluster |
| <a name="output_ingress_address"></a> [ingress\_address](#output\_ingress\_address) | Application Gateway public/private IP assigned by AGIC — use this to configure the FortiGate and chatbot |
| <a name="output_ingress_host"></a> [ingress\_host](#output\_ingress\_host) | Configured ingress hostname (empty = matches all hosts) |
| <a name="output_internal_tls_ca_certificate"></a> [internal\_tls\_ca\_certificate](#output\_internal\_tls\_ca\_certificate) | Public generated CA certificate for internal services and database TLS in every certificate mode. Separate from web/API trust when using supplied certificates or Let's Encrypt. |
| <a name="output_location"></a> [location](#output\_location) | Azure region used for the deployment |
| <a name="output_release_status"></a> [release\_status](#output\_release\_status) | Helm release deployment status |
| <a name="output_resource_group_name"></a> [resource\_group\_name](#output\_resource\_group\_name) | Resource group containing the AKS cluster |
| <a name="output_storage_account_name"></a> [storage\_account\_name](#output\_storage\_account\_name) | Storage account name backing the shared PVC |
| <a name="output_tls_ca_certificate"></a> [tls\_ca\_certificate](#output\_tls\_ca\_certificate) | PEM root CA for web/API HTTPS: generated CA by default, supplied root CA when configured, or empty for publicly trusted certificates. Import private CAs into client trust stores. Public certificate, not a secret. |
<!-- END_TF_DOCS -->
