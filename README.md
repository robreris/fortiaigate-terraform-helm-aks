# FortiAIGate on Azure AKS — Terraform + Helm

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)
[![Terraform](https://img.shields.io/badge/terraform-%E2%89%A51.5-623CE4.svg)](https://www.terraform.io/)
[![Kubernetes](https://img.shields.io/badge/kubernetes-1.35-326CE5.svg)](https://kubernetes.io/)

Terraform stack that deploys FortiAIGate on Azure AKS.

The local Helm chart is based on the downloaded FortiAIGate 8.0.2/build0055
chart, with AKS-specific ingress, storage, TLS, license, and GPU placement
patches. The default application and Triton image tags match build0055.

On the `v803` branch, [stage the 8.0.3 build 6207 images in ACR](docs/registry-build6207.md) and follow the [AKS chart port notes](docs/build6207-compatibility.md). The quickstart below currently deploys 8.0.2 build 0055. Use `main` for 8.0.2 deployments.

## What you get

- A resource group holding the VNet, AKS cluster, Azure Files storage account, and (optionally) the Application Gateway.
- AKS cluster with:
  - An `app` node pool (default 1x `Standard_D16s_v5`, `max_pods` raised to 110) for FortiAIGate application services and the Bitnami PostgreSQL/Redis subcharts. Workloads select the app pool independently of deployment licensing.
  - An optional `gpu` node pool (default 1x `Standard_NV36ads_A10_v5`, an A10) for Triton/vLLM, tainted so only GPU workloads land there. The combined build0055 workload still needs hardware/runtime qualification — see [docs/gpu-triton-compatibility.md](docs/gpu-triton-compatibility.md).
  - OIDC issuer and workload identity enabled.
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

Use Application Gateway + Azure DNS (or your DNS provider) + a trusted TLS
certificate. See [Application Gateway, DNS, and TLS](docs/application-gateway-dns-tls.md).
To deploy with your own certificate and private key, see [Supplied TLS certificates](docs/tls-supplied.md).

### Why two steps?

The `helm` and `kubernetes` providers in `providers.tf` read connection details from `azurerm_kubernetes_cluster.this.kube_config`. On a clean apply the cluster doesn't exist yet, so any single-shot run fails when Terraform tries to plan the helm/kubernetes resources. Bootstrap the infra first, then apply the rest. Subsequent applies don't need targeting.

Bootstrap the GPU pool with the infrastructure when enabled so inference can
schedule during the full apply. Build0055 does not require node-name discovery
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

## Configuration

See [deployment and configuration](docs/deployment-guide.md) for common inputs and GPU tuning, and [the generated Terraform reference](docs/terraform-reference.md) for all inputs, resources, and outputs. Use [technical notes](docs/technical-notes.md) when modifying value precedence or resource ownership.

## Testing and release readiness

Run the local checks in [CONTRIBUTING.md](CONTRIBUTING.md), then follow the
[deployment test checklist](docs/testing.md) in a dedicated Azure subscription.
The [roadmap](ROADMAP.md) records remaining production gaps; the production
tfvars example is a starting configuration, not a high-availability guarantee.

## Documentation

- [Build 6207 ACR staging](docs/registry-build6207.md) and [8.0.3 AKS port notes](docs/build6207-compatibility.md).
- [Build0055 port and upgrade notes](docs/build0055-compatibility.md) — image inventory, upgrade expectations, and qualification gaps.
- [Deployment and configuration](docs/deployment-guide.md) — architecture, common variables, and GPU tuning.
- [Terraform reference](docs/terraform-reference.md) — generated inputs, resources, and outputs.
- [Technical notes](docs/technical-notes.md) and [teardown](docs/teardown.md) — implementation constraints and removal.
- [8.0.1 to 8.0.2 upgrade](docs/upgrade-8.0.1-to-8.0.2.md) — branch comparison, secret adoption, migration prerequisites, cutover, and recovery.
- [Operations and upgrades](docs/operations.md) — credential adoption, licensing, storage constraints, and rollouts.
- [Supplied TLS certificates](docs/tls-supplied.md) — use your own certificate while retaining internal database TLS.
- [Application Gateway, DNS, and TLS](docs/application-gateway-dns-tls.md) — gateway ownership, DNS, and backend trust.
- [Container registry and image upload](docs/registry-and-images.md) — ACR, image push, and `AcrPull`.
- [GPU and Triton compatibility](docs/gpu-triton-compatibility.md) — supported Azure GPU SKUs and quota.
- [Permissions pre-flight](docs/permissions-preflight.md) — Azure RBAC and provider checks before apply.
- [Remote state](docs/remote-state.md) — Azure Storage backend bootstrap.

## Teardown

Follow [staged teardown](docs/teardown.md) while AKS and its controllers are available. Back up PostgreSQL, Redis, Azure Files data, encryption keys, and state first. Full destruction deletes the managed storage account; namespace/PVC deletion can also delete database disks. `Retain` on the shared StorageClass does not protect storage from Terraform destruction.

## License

Apache 2.0 — see [LICENSE](LICENSE).
