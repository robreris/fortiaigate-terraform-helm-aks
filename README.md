# FortiAIGate on Azure AKS — Terraform + Helm

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)
[![Terraform](https://img.shields.io/badge/terraform-%E2%89%A51.5-623CE4.svg)](https://www.terraform.io/)
[![Kubernetes](https://img.shields.io/badge/kubernetes-1.31-326CE5.svg)](https://kubernetes.io/)

Terraform stack that deploys FortiAIGate on Azure AKS.

## What you get

- A resource group holding the VNet, AKS cluster, Azure Files storage account, and (optionally) the Application Gateway.
- AKS cluster with:
  - An `app` node pool (default 1x `Standard_D16s_v5`, `max_pods` raised to 110) for FortiAIGate core services and the Bitnami PostgreSQL/Redis subcharts. Sized to the number of app-node licenses — node-keyed licensing pins all pods to licensed nodes, so the full service set runs on the one licensed node.
  - An optional `gpu` node pool (default 1x `Standard_NV36ads_A10_v5`, an A10) for Triton inference, tainted so only GPU workloads land there. The GPU must be a Fortinet-supported model with ≥24 GB VRAM and SM 75+ — see [docs/gpu-triton-compatibility.md](docs/gpu-triton-compatibility.md).
  - OIDC issuer and workload identity enabled (AKS analogue of EKS IRSA).
  - AGIC addon (optional) — AKS provisions and manages an Application Gateway in a dedicated subnet.
- A Premium Azure Files storage account, the kubelet identity role assignments needed for dynamic file-share provisioning, and an `azurefile-fortiaigate` StorageClass.
- The `fortiaigate` Helm release, with a self-signed TLS cert generated at apply time and (optionally) per-node licenses sourced from a ConfigMap.

## Prerequisites

- Terraform `>= 1.5`
- Azure CLI signed in (`az login`) with rights to:
  - Create resource groups, VNets, AKS clusters, role assignments, and storage accounts in the target subscription.
  - The signed-in principal becomes the AKS cluster admin via the default AAD passthrough behavior.
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
  -var-file=tfvars/dev.tfvars

# (drop the gpu node pool target if gpu_enabled = false — it resolves to zero
#  resources and the target is harmlessly ignored, so it's safe to leave in)

# Both node pools now exist. Discover node names and set var.licenses before
# the full apply (see node-keyed licensing notes):
#   $(terraform output -raw configure_kubectl)
#   kubectl get nodes -o custom-columns=NAME:.metadata.name,ROLE:.metadata.labels.fortiaigate-role --no-headers
#
# If gpu_enabled = true, var.licenses must include the aks-gpu-* node too;
# Triton is pinned to both the GPU node selector and licensed hostnames.

terraform apply -var-file=tfvars/dev.tfvars

# 4. Talk to the cluster
$(terraform output -raw configure_kubectl)
kubectl get pods,pvc,ingress -n fortiaigate
terraform output ingress_address
```

### Why two steps?

The `helm` and `kubernetes` providers in `providers.tf` read connection details from `azurerm_kubernetes_cluster.this.kube_config`. On a clean apply the cluster doesn't exist yet, so any single-shot run fails when Terraform tries to plan the helm/kubernetes resources. Bootstrap the infra first, then apply the rest. Subsequent applies don't need targeting.

Only the helm/kubernetes resources have to wait — every `azurerm` resource can go in step 1. The GPU node pool (`azurerm_kubernetes_cluster_node_pool.gpu`) is therefore included in the first apply so **both** node pools exist before the full apply. That's what lets you discover the real node names and populate `var.licenses` between the two steps (node-keyed licensing). If the GPU pool is left for the second apply, its node name isn't knowable until the same apply that also wires in the licenses, which makes the hostname-affinity licensing impossible to satisfy on first deploy.

## Per-subscription layout

State, backend, and variables are partitioned by Azure subscription:

| Path | Purpose | Tracked in git? |
|------|---------|-----------------|
| `backends/<name>.hcl.example` | Template for a backend config | Yes |
| `backends/<name>.hcl` | Actual backend config (storage account, container, key) | No (gitignored) |
| `tfvars/<name>.tfvars.example` | Template for a tfvars file | Yes |
| `tfvars/<name>.tfvars` | Actual variable values (image repo, ingress host, licenses) | No (gitignored) |

To switch subscriptions, set the AZ context (`az account set --subscription <id>`), then re-init with the new backend: `terraform init -backend-config=backends/<new>.hcl -reconfigure`.

## Common variables

| Variable | Default | Notes |
|----------|---------|-------|
| `location` | `eastus` | Azure region. Must have quota for the chosen VM sizes — A10/A100 GPU families are request-only (default 0) in most regions. |
| `cluster_name` | `fortiaigate` | Used as the AKS name, DNS prefix, and (after stripping) the storage account name prefix. |
| `app_node_count` | `1` | Number of **licensed** app nodes; pool is pinned (min=max). Pods are pinned to licensed nodes, so set this to your app-node license count. |
| `app_node_max_pods` | `110` | Per-node pod cap. Raised above the Azure CNI default of 30 so the whole service set fits on the one licensed app node. |
| `gpu_enabled` | `false` | Set true to add the GPU node pool + nvidia-device-plugin Helm release + Triton workloads. Needs a supported GPU + quota (see prerequisites). |
| `gpu_node_vm_size` | `Standard_NV36ads_A10_v5` | A10 (24 GB, SM 86). Must be a Fortinet-supported GPU with ≥24 GB VRAM and SM 75+; the V100 fails. |
| `acr_id` | `""` | Set to the ACR resource ID to codify the kubelet `AcrPull` grant; leave empty if managed elsewhere. |
| `db_storage_class` | `managed-csi` | Block (RWO) StorageClass for PostgreSQL/Redis — they cannot run on the shared Azure Files (SMB) class. |
| `agic_enabled` | `true` | Disable to use ingress-nginx or web_app_routing instead. |
| `ingress_class` | `azure-application-gateway` | Must match the installed controller. |
| `internal` | `false` | True puts the AGIC ingress on the Application Gateway's private frontend IP. |
| `image_repository` | *(required)* | e.g. `myregistry.azurecr.io/fortiaigate`. |
| `licenses` | `{}` | `{ "aks-app-xxxxxxxx-vmss000000" = "licenses/APP.lic", "aks-gpu-xxxxxxxx-vmss000000" = "licenses/GPU.lic" }`. Populate after step 1 with the real node names; include the GPU node when `gpu_enabled = true`. |

Full list in `variables.tf`.

## Teardown

Order matters — Helm finalizers (PVCs, the Application Gateway's listener bindings) can block `terraform destroy` if released out of order:

```bash
helm -n fortiaigate uninstall fortiaigate
helm -n kube-system uninstall nvidia-device-plugin     # if gpu_enabled

# Wait for PVCs/ingresses to clear, then:
terraform destroy -var-file=tfvars/dev.tfvars
```

The Azure Files storage account is part of the resource group and goes away with `destroy`. The PVs have `Retain` set, so the underlying shares survive until the storage account itself is dropped; back them up first if you need their contents.

## License

Apache 2.0 — see `LICENSE`.
