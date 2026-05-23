# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo deploys

A single Terraform stack that stands up FortiAIGate on Azure AKS:

- Resource Group + VNet + AKS cluster + app/GPU node pools
- Azure Files storage account (required — the chart's shared PVC is `ReadWriteMany`, which Azure managed disks cannot satisfy)
- Application Gateway Ingress Controller (AGIC) addon (conditional)
- The `fortiaigate/` Helm chart (local path, shared with the EKS stack), which bundles Bitnami PostgreSQL and Redis subcharts

There is no application source code here — this repo is purely IaC. FortiAIGate container images come from an external registry referenced via `var.image_repository` (typically Azure Container Registry, e.g. `<name>.azurecr.io/fortiaigate`).

This repo is the Azure twin of `fortiaigate-terraform-helm-eks` (sibling working directory at `/home/robert/GitRepos/robreris/fortiaigate-terraform-helm-eks`). The Helm chart under `fortiaigate/` is intentionally identical between the two — only the Terraform root differs. When changing the chart, change it in both repos.

## Current state

Pure scaffold — **nothing in this repo has been applied yet**. No state file exists, no remote-state container exists, no cluster has been built. The next session is expected to:

1. Run the bootstrap in `docs/remote-state.md` to create the state storage account.
2. Run the checks in `docs/permissions-preflight.md` to confirm the SP has `Contributor` + `User Access Administrator` (or `Owner`).
3. Do the two-step first apply.

The user authenticates Terraform via service principal env vars: `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`.

### Known open follow-ups

- **ACR pull role for kubelet identity is not in this stack.** The AKS kubelet identity needs `AcrPull` on whichever Azure Container Registry holds the FortiAIGate images. Conventionally that lives in the registry's own Terraform repo, so it isn't created here. If the registry is in this same RG it could be added; ask before doing so.
- **Chart audit confirmed no AGIC changes needed.** `templates/ingress.yaml`, `api.yaml`, and `core.yaml` only inject ALB/nginx/traefik defaults inside `if eq .Values.ingress.className "..."` blocks — AGIC users supply annotations via `var.ingress_annotations`. The dev tfvars example shows the typical set (`backend-protocol`, `ssl-redirect`, `health-probe-path`, `health-probe-status-codes`). No chart-side edit is owed.
- **Workload Identity is enabled on the cluster but not yet consumed.** `oidc_issuer_enabled` and `workload_identity_enabled` are on in `aks.tf` so the chart can later bind service accounts to Azure AD identities (the AKS analogue of EKS IRSA). Currently nothing in the chart uses them — the azurefile-csi driver authenticates via the storage account key path.

## Common commands

```bash
# Per-subscription init (switching subscriptions uses -reconfigure, NOT -migrate-state)
terraform init -backend-config=backends/<subscription>.hcl -reconfigure

# First-time deploy MUST be two-step — see "Two-step apply" below
terraform apply -target=azurerm_resource_group.this -target=azurerm_virtual_network.this -target=azurerm_subnet.aks -target=azurerm_subnet.appgw -target=azurerm_kubernetes_cluster.this -var-file=tfvars/<subscription>.tfvars
terraform apply -var-file=tfvars/<subscription>.tfvars

# Configure kubectl after cluster exists
$(terraform output -raw configure_kubectl)

# Verify the deployment
kubectl get pods,pvc,ingress -n fortiaigate
terraform output ingress_address
```

Teardown order matters — uninstall Helm releases first, then `terraform destroy`. Otherwise Terraform deletes infra out from under finalizers (Application Gateway, PVCs) and times out. The Azure Files storage account is `Retain` for the StorageClass (PVs survive) but the storage account itself is destroyed with the resource group; back up shares first if their content matters. Full steps in `README.md`.

## Two-step apply (critical)

The `helm` and `kubernetes` providers in `providers.tf` authenticate via the kubeconfig emitted by `azurerm_kubernetes_cluster.this.kube_config`. On a first apply the cluster doesn't exist yet, so any single-shot `terraform apply` will fail trying to plan helm/kubernetes resources. Always bootstrap the resource group, network, and AKS cluster first, then apply the rest. Subsequent applies can be single-step.

If a previous apply errored partway through the network resources, the AKS cluster will fail to create with subnet validation errors. Re-run `terraform apply -target=azurerm_subnet.aks -target=azurerm_subnet.appgw` before re-attempting the full apply.

## Per-subscription layout

State, backend, and variables are partitioned by Azure subscription, not by workspace:

- `backends/<subscription>.hcl` — committed example only; `*.hcl` is gitignored. Holds the storage account / container names, no secrets.
- `tfvars/<subscription>.tfvars` — gitignored; `*.tfvars.example` files are committed templates

To switch subscriptions: `az account set --subscription <id>`, then `terraform init -backend-config=backends/<new>.hcl -reconfigure`. Each subscription uses its own state storage account and container (one-time bootstrap in `README.md`).

## Architecture quirks worth knowing

**Azure Files (not Azure Disks) backs the shared PVC.** `storage.tf` provisions a Premium FileStorage account, grants the AKS kubelet identity `Storage Account Contributor` and `Storage File Data SMB Share Contributor`, and creates an `azurefile-fortiaigate` StorageClass pinned to that account. Azure managed disks are RWO only and cannot satisfy the chart's RWX claim. If Azure Files performance is insufficient, switch to Azure NetApp Files (NFSv4.1) — that requires a delegated subnet and ANF capacity pool, neither of which this stack creates.

**AGIC is enabled via the AKS addon, not a separate Helm release.** `azurerm_kubernetes_cluster.this.ingress_application_gateway` (conditional on `var.agic_enabled`) tells AKS to create and manage an Application Gateway in the `appgw` subnet. Disable it to use ingress-nginx or the web_app_routing addon instead. When AGIC is disabled, the ingress resource still gets created by the chart but stays without an address until an externally-managed controller picks it up.

**Two subnets are required, even when AGIC is off.** `network.tf` always creates both `aks` and `appgw` subnets so subnet IDs stay stable when AGIC is toggled. This avoids replacing the cluster's network config to add or remove AGIC later.

**Internal vs internet-facing Application Gateway.** `var.internal = true` adds an `appgw.ingress.kubernetes.io/use-private-ip: "true"` annotation via `local.internal_appgw_values`. Placed *before* `ingress_annotation_values` in the merge order so explicit user annotations still override. The Application Gateway itself still has a public IP (AGIC requires it), but the listener binds to the private frontend.

**TLS is self-signed at apply time** (`tls.tf`). The cert's SHA256 is passed to the Helm release as `tls.existingSecretChecksum` so pod template annotations trigger a rollout when the cert is regenerated. For production, replace with Key Vault-issued certs (AGIC supports them via the `appgw.ingress.kubernetes.io/appgw-ssl-certificate` annotation) or cert-manager.

**Helm values are composed by `concat()` of `yamlencode`'d locals in `helm.tf`.** Set blocks can't handle YAML lists (tolerations) or keys with dots/slashes (ingress annotations), so structured values go through `yamlencode`. Order matters — later entries win. Currently: `extra_values_files` → `gpu_values` → `internal_appgw_values` → `ingress_annotation_values` → `tls_values` → `license_node_values`. When adding a new structured override, decide where it belongs in that precedence chain.

**Licenses are node-keyed.** `var.licenses` maps AKS node names (e.g. `aks-app-12345678-vmss000000`) to local license file paths. `licenses.tf` reads each file and stuffs it in a `fortiaigate-license-config` ConfigMap; the license-manager DaemonSet uses node affinity on the names to deliver the right license to each node. Node names must match `kubectl get nodes` output exactly — they're discovered post-apply, so the initial deploy runs without licenses and a second apply adds them. Note: AKS VMSS-generated node names change when node pools are upgraded or scaled in, so license assignments may need re-keying after pool churn.

**GPU is optional and tainted.** `var.gpu_enabled = true` adds a single-node `Standard_NC6s_v3` pool by default, tainted `fortiaigate-gpu=true:NoSchedule`. Terraform also installs the NVIDIA device plugin Helm release with matching tolerations. Triton is the only workload scheduled there. AKS does not ship a GPU-specific Ubuntu image variant — the standard AKS image plus the NVIDIA device plugin DaemonSet handles driver installation.

**Storage account naming has a hard 24-char limit.** `local.storage_account_name` strips non-alphanumerics from `var.cluster_name`, appends an 8-char random suffix, then truncates. If you change `cluster_name`, the random suffix changes too and Terraform will plan to replace the storage account — destroying all PVC data on it. Lift-and-shift between cluster names requires migrating the shares first.

## File map (terraform root)

| File | What it owns |
|------|--------------|
| `network.tf` | Resource Group, VNet, AKS subnet, Application Gateway subnet |
| `aks.tf` | AKS cluster, app + GPU node pools, OIDC issuer, workload identity, AGIC addon (conditional) |
| `storage.tf` | Azure Files storage account, kubelet role assignments, `azurefile-fortiaigate` StorageClass |
| `helm.tf` | `fortiaigate` namespace, NVIDIA device plugin, fortiaigate Helm release, value composition |
| `licenses.tf` | `fortiaigate-license-config` ConfigMap from `var.licenses` |
| `tls.tf` | Self-signed cert + `fortiaigate-tls-secret` |
| `providers.tf` | azurerm + azuread + helm + kubernetes providers (helm/kubernetes use the AKS-emitted kubeconfig) |
| `backend.tf` | Empty azurerm backend; values supplied via `-backend-config` |
| `outputs.tf` | Cluster name, kubectl command, storage account name, ingress address (data-source lookup of the ingress) |
| `docs/remote-state.md` | One-time per-subscription bootstrap: RG + Storage Account + container for the state blob, plus SP `Storage Blob Data Contributor` grant |
| `docs/permissions-preflight.md` | What roles the Terraform SP needs (`Contributor` + `User Access Administrator`, or `Owner`), how to check RP registrations and vCPU quota |
