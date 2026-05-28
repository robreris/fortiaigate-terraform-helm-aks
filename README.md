# fortiaigate-terraform-helm-aks

Terraform stack that deploys FortiAIGate on Azure AKS.

## What you get

- A resource group holding the VNet, AKS cluster, Azure Files storage account, and (optionally) the Application Gateway.
- AKS cluster with:
  - An `app` node pool (default 2x `Standard_D16s_v5`) for FortiAIGate core services and the Bitnami PostgreSQL/Redis subcharts.
  - An optional `gpu` node pool (default 1x `Standard_NC6s_v3`) for Triton inference, tainted so only GPU workloads land there.
  - OIDC issuer and workload identity enabled (AKS analogue of EKS IRSA).
  - AGIC addon (optional) — AKS provisions and manages an Application Gateway in a dedicated subnet.
- A Premium Azure Files storage account, the kubelet identity role assignments needed for dynamic file-share provisioning, and an `azurefile-fortiaigate` StorageClass.
- The `fortiaigate` Helm release, with a self-signed TLS cert generated at apply time and (optionally) per-node licenses sourced from a ConfigMap.

## Prerequisites

- Terraform `>= 1.5`
- Azure CLI signed in (`az login`) with rights to:
  - Create resource groups, VNets, AKS clusters, role assignments, and storage accounts in the target subscription.
  - The signed-in principal becomes the AKS cluster admin via the default AAD passthrough behavior.
- A container registry holding the FortiAIGate images (typically an Azure Container Registry — `<name>.azurecr.io`). The AKS kubelet identity must have `AcrPull` on it; that role assignment is **not** managed by this stack and must be granted separately. See [docs/registry-and-images.md](docs/registry-and-images.md) for creating the registry, pushing the images, and granting `AcrPull`.
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
| `location` | `eastus` | Azure region. Must have quota for the chosen VM sizes (NCsv3 GPU quota is request-only in many regions). |
| `cluster_name` | `fortiaigate` | Used as the AKS name, DNS prefix, and (after stripping) the storage account name prefix. |
| `app_node_count` | `2` | Min 1; autoscale max is `count + 2`. |
| `gpu_enabled` | `false` | Set true to add the GPU node pool + nvidia-device-plugin Helm release + Triton workloads. |
| `agic_enabled` | `true` | Disable to use ingress-nginx or web_app_routing instead. |
| `ingress_class` | `azure-application-gateway` | Must match the installed controller. |
| `internal` | `false` | True puts the AGIC ingress on the Application Gateway's private frontend IP. |
| `image_repository` | *(required)* | e.g. `myregistry.azurecr.io/fortiaigate`. |
| `licenses` | `{}` | `{ "aks-app-xxxxxxxx-vmss000000" = "licenses/NODE.lic" }`. Populate after the first apply. |

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
