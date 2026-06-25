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

**Deployed and validated end-to-end** (full clean rebuild on 2026-05-28). The two-step apply path works from scratch: cluster (`fortiaigate-dev`, K8s 1.35) with one licensed app node (`max_pods` 110) + one A10 GPU node, all services running including Triton on the A10 and PostgreSQL on `managed-csi`. The one operational caveat is licensing, not infra — see below.

For a **from-scratch deploy** (new subscription/operator), the sequence is:

1. Run the bootstrap in `docs/remote-state.md` to create the state storage account.
2. Run the checks in `docs/permissions-preflight.md` to confirm the SP has `Contributor` + `User Access Administrator` (or `Owner`).
3. If `gpu_enabled`, request A10/A100 quota in the target region first (defaults to 0) — see `docs/gpu-triton-compatibility.md`.
4. Do the two-step first apply (discover node names after step 1, set `var.licenses`, then full apply).

The user authenticates Terraform via service principal env vars: `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`.

**Licensing caveat (the one gotcha).** FortiAIGate node licenses can stick in a "License status: In Use" state — bound to a prior deployment whose nodes were torn down. `core` gates its readiness probe on a valid (not "in use") license, returning 503 until the seat frees, so the `helm_release`/`terraform apply` will time out waiting on `core` even though everything else is healthy. The seat auto-releases within ~24h of the old nodes disappearing (or release it manually in the FortiFlex/FortiCare portal). The same node-keyed licensing pins all pods to licensed nodes (see the "Node-keyed licensing pins ALL workload pods" note below), which is why `app_node_count` tracks the license count and `app_node_max_pods` is raised.

### Known open follow-ups

- **ACR pull role for kubelet identity — now codified (optional).** The AKS kubelet identity needs `AcrPull` on whichever ACR holds the FortiAIGate images, or every pod stalls in `ImagePullBackOff` (kubelet falls back to an anonymous token → 401) and the helm release / `terraform apply` hangs. `aks.tf` creates this grant via `azurerm_role_assignment.kubelet_acr_pull`, conditional on `var.acr_id`. Leave `acr_id` empty when the ACR (and its grant) is owned by another stack; set it to the ACR resource ID otherwise (the Terraform SP then needs role-assignment write on that scope). Note: each cluster recreate mints a NEW kubelet identity, so a one-off `az aks update --attach-acr` does not survive teardown — that's why codifying it matters.
- **Chart audit confirmed no AGIC changes needed.** `templates/ingress.yaml`, `api.yaml`, and `core.yaml` only inject ALB/nginx/traefik defaults inside `if eq .Values.ingress.className "..."` blocks — AGIC users supply annotations via `var.ingress_annotations`. The dev tfvars example shows the typical set (`backend-protocol`, `ssl-redirect`, `health-probe-path`, `health-probe-status-codes`). No chart-side edit is owed.
- **Workload Identity is now consumed by cert-manager (optional Let's Encrypt path).** `oidc_issuer_enabled` and `workload_identity_enabled` are on in `aks.tf` (the AKS analogue of EKS IRSA). The first consumer is `certmanager.tf`: when `var.letsencrypt_enabled = true`, a user-assigned identity federated to the cert-manager ServiceAccount (no secret) holds `DNS Zone Contributor` on an external Azure DNS zone, and cert-manager issues a browser-trusted cert into `fortiaigate-tls-secret` via ACME DNS-01. The azurefile-csi driver still authenticates via the storage account key path, not workload identity.

## Common commands

```bash
# Per-subscription init (switching subscriptions uses -reconfigure, NOT -migrate-state)
terraform init -backend-config=backends/<subscription>.hcl -reconfigure

# First-time deploy MUST be two-step — see "Two-step apply" below
terraform apply -target=azurerm_resource_group.this -target=azurerm_virtual_network.this -target=azurerm_subnet.aks -target=azurerm_subnet.appgw -target=azurerm_kubernetes_cluster.this -target=azurerm_kubernetes_cluster_node_pool.gpu -var-file=tfvars/<subscription>.tfvars
# (the gpu pool target resolves to zero resources when gpu_enabled = false, so it's safe to leave in)
# Both node pools now exist — discover node names and set var.licenses before the full apply.
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

Only the helm/kubernetes resources are subject to this — every `azurerm` resource can go in the first apply, and the GPU node pool (`azurerm_kubernetes_cluster_node_pool.gpu`) deliberately does. Putting both node pools up in step 1 is what makes node-keyed licensing work: the GPU node name is discoverable between the two applies, so `var.licenses` can be populated before the full apply renders the hostname `nodeAffinity` blocks. If the GPU pool is deferred to the second apply, its node name only exists in the same apply that consumes the licenses, so the affinity can never be satisfied on a first deploy and the GPU node ends up unschedulable/reclaimed.

If a previous apply errored partway through the network resources, the AKS cluster will fail to create with subnet validation errors. Re-run `terraform apply -target=azurerm_subnet.aks -target=azurerm_subnet.appgw` before re-attempting the full apply.

## Per-subscription layout

State, backend, and variables are partitioned by Azure subscription, not by workspace:

- `backends/<subscription>.hcl` — committed example only; `*.hcl` is gitignored. Holds the storage account / container names, no secrets.
- `tfvars/<subscription>.tfvars` — gitignored; `*.tfvars.example` files are committed templates

To switch subscriptions: `az account set --subscription <id>`, then `terraform init -backend-config=backends/<new>.hcl -reconfigure`. Each subscription uses its own state storage account and container (one-time bootstrap in `README.md`).

## Architecture quirks worth knowing

**Azure Files (not Azure Disks) backs the shared PVC — but NOT the databases.** `storage.tf` provisions a Premium FileStorage account, grants the AKS kubelet identity `Storage Account Contributor` and `Storage File Data SMB Share Contributor`, and creates an `azurefile-fortiaigate` StorageClass pinned to that account. Azure managed disks are RWO only and cannot satisfy the chart's RWX claim. If Azure Files performance is insufficient, switch to Azure NetApp Files (NFSv4.1) — that requires a delegated subnet and ANF capacity pool, neither of which this stack creates.

**PostgreSQL and Redis run on Azure Disk, not the shared Azure Files claim.** The chart's `values.yaml` defaults both Bitnami subcharts to `existingClaim: "fortiaigate-storage"` (the RWX SMB share), but PostgreSQL's `initdb` fails on SMB — it needs a data dir owned by the db user at 0700 with POSIX fsync/locking, which CIFS/SMB cannot provide, so the pod crashloops (exit 1) right before initdb. `local.db_storage_values` in `helm.tf` overrides both to dynamically-provisioned RWO disks via `var.db_storage_class` (default `managed-csi`). Done Terraform-side, not in the chart, so the chart stays identical to the EKS stack — the EKS root needs its own equivalent override (gp3/EBS) and likely has the same latent EFS issue. Switching an *already-deployed* postgres/redis from `existingClaim` to a volumeClaimTemplate requires deleting the StatefulSets first (`volumeClaimTemplates` is immutable); safe pre-first-successful-init since there's no data.

**AGIC is enabled via the AKS addon, not a separate Helm release.** `azurerm_kubernetes_cluster.this.ingress_application_gateway` (conditional on `var.agic_enabled`) tells AKS to create and manage an Application Gateway in the `appgw` subnet. Disable it to use ingress-nginx or the web_app_routing addon instead. When AGIC is disabled, the ingress resource still gets created by the chart but stays without an address until an externally-managed controller picks it up.

**Two subnets are required, even when AGIC is off.** `network.tf` always creates both `aks` and `appgw` subnets so subnet IDs stay stable when AGIC is toggled. This avoids replacing the cluster's network config to add or remove AGIC later.

**Internal vs internet-facing Application Gateway.** `var.internal = true` adds an `appgw.ingress.kubernetes.io/use-private-ip: "true"` annotation via `local.internal_appgw_values`. Placed *before* `ingress_annotation_values` in the merge order so explicit user annotations still override. The Application Gateway itself still has a public IP (AGIC requires it), but the listener binds to the private frontend.

**TLS is self-signed at apply time** (`tls.tf`) **by default, or Let's Encrypt via cert-manager when `var.letsencrypt_enabled = true`.** In the default path the cert's SHA256 is passed to the Helm release as `tls.existingSecretChecksum` so pod template annotations trigger a rollout when the cert is regenerated. When Let's Encrypt is enabled, `tls.tf`'s three resources resolve to zero (count) and cert-manager owns `fortiaigate-tls-secret` instead — the checksum then keys off `letsencrypt_environment` so flipping staging→production rolls the pods. Because the chart's ingress `spec.tls` references that same secret, AGIC serves it as the frontend listener cert AND trusts the HTTPS backend (well-known CA chain), which is what fixes the self-signed backend 502 (`The Intermediate certificate is missing from the backend server chain`). The `ClusterIssuer`/`Certificate` ship as a local `certmanager-issuer/` chart, not a `kubernetes_manifest`, to avoid the plan-time CRD dry-run failure. Full walkthrough: `docs/tls-letsencrypt.md`.

**Helm values are composed by `concat()` of `yamlencode`'d locals in `helm.tf`.** Set blocks can't handle YAML lists (tolerations) or keys with dots/slashes (ingress annotations), so structured values go through `yamlencode`. Order matters — later entries win. Currently: `extra_values_files` → `gpu_values` → `db_storage_values` → `internal_appgw_values` → `ingress_annotation_values` → `tls_values` → `license_node_values`. When adding a new structured override, decide where it belongs in that precedence chain.

**Licenses are node-keyed.** `var.licenses` maps AKS node names (e.g. `aks-app-12345678-vmss000000`) to local license file paths. `licenses.tf` reads each file and stuffs it in a `fortiaigate-license-config` ConfigMap; the license-manager DaemonSet uses node affinity on the names to deliver the right license to each node. Node names must match `kubectl get nodes` output exactly — they're discovered post-apply, so the initial deploy runs without licenses and a second apply adds them. Note: AKS VMSS-generated node names change when node pools are upgraded or scaled in, so license assignments may need re-keying after pool churn.

**Node-keyed licensing pins ALL workload pods to licensed nodes — this drives node sizing.** The chart renders a *hard* `requiredDuringScheduling` hostname `nodeAffinity` (`kubernetes.io/hostname In [<keys of var.licenses>]`) onto the workload pods, not just license-manager. Consequences: (1) pods only schedule on nodes listed in `var.licenses` — an unlicensed node runs system daemonsets only and is invisible to the workload, so adding nodes without licenses does nothing for capacity; (2) **node count should equal license count** (`app_node_count` is now the licensed-app-node count, default 1, pool pinned `min=max`); (3) all app pods are therefore forced onto the licensed app node(s), and the full service set (~15 app pods + ~9 system daemonsets) exceeds Azure CNI's default 30 pods/node — so `var.app_node_max_pods` (default 110) raises the cap (set at pool creation; classic Azure CNI draws one subnet IP per pod, fine within the `/20` `aks_subnet_cidr`). Symptom if the cap is too low: app node at 30/30 and pods (e.g. `webui`) stuck `Pending` with "didn't match node affinity/selector". A node-pool recreate (e.g. GPU VM-size change) mints a new node name that must be re-keyed into `var.licenses` or the workload pinned to that node (e.g. triton) stays Pending.

**GPU is optional and tainted.** `var.gpu_enabled = true` adds a single-node `Standard_NV36ads_A10_v5` (A10, 24 GB) pool by default, tainted `fortiaigate-gpu=true:NoSchedule`. Terraform also installs the NVIDIA device plugin Helm release with matching tolerations. Triton is the only workload scheduled there. The GPU must be a Fortinet-supported model (A10/A100) with ≥24 GB VRAM **and** SM 75+ for the Triton image's TensorRT 10 — the older V100 fails both; see `docs/gpu-triton-compatibility.md`. AKS does not ship a GPU-specific Ubuntu image variant — the standard AKS image plus the NVIDIA device plugin DaemonSet handles driver installation.

The GPU node pool pins `gpu_driver = "Install"` (`aks.tf`). This is mandatory, not cosmetic: azurerm records `gpu_driver` as `"Install"` when a GPU pool is created, the field is ForceNew, and leaving it unset makes the provider plan it to `null` — which silently schedules a **destroy/recreate of the pool on the next apply**. That replacement hands the node a new name and re-keys (i.e. breaks) the hostname-affinity licensing. Keep the argument set.

**Storage account naming has a hard 24-char limit.** `local.storage_account_name` strips non-alphanumerics from `var.cluster_name`, appends an 8-char random suffix, then truncates. If you change `cluster_name`, the random suffix changes too and Terraform will plan to replace the storage account — destroying all PVC data on it. Lift-and-shift between cluster names requires migrating the shares first.

## File map (terraform root)

| File | What it owns |
|------|--------------|
| `network.tf` | Resource Group, VNet, AKS subnet, Application Gateway subnet |
| `aks.tf` | AKS cluster, app + GPU node pools, OIDC issuer, workload identity, AGIC addon (conditional) |
| `storage.tf` | Azure Files storage account, kubelet role assignments, `azurefile-fortiaigate` StorageClass |
| `helm.tf` | `fortiaigate` namespace, NVIDIA device plugin, fortiaigate Helm release, value composition |
| `licenses.tf` | `fortiaigate-license-config` ConfigMap from `var.licenses` |
| `tls.tf` | Self-signed cert + `fortiaigate-tls-secret` (only when `letsencrypt_enabled = false`) |
| `certmanager.tf` | (optional) cert-manager install + workload-identity-federated UAMI + DNS Zone Contributor + ACME ClusterIssuer/Certificate, gated on `var.letsencrypt_enabled` |
| `certmanager-issuer/` | Local Helm chart holding the `ClusterIssuer` + `Certificate` (avoids the `kubernetes_manifest` plan-time CRD problem) |
| `providers.tf` | azurerm + azuread + helm + kubernetes providers (helm/kubernetes use the AKS-emitted kubeconfig) |
| `backend.tf` | Empty azurerm backend; values supplied via `-backend-config` |
| `outputs.tf` | Cluster name, kubectl command, storage account name, ingress address (data-source lookup of the ingress) |
| `docs/remote-state.md` | One-time per-subscription bootstrap: RG + Storage Account + container for the state blob, plus SP `Storage Blob Data Contributor` grant |
| `docs/permissions-preflight.md` | What roles the Terraform SP needs (`Contributor` + `User Access Administrator`, or `Owner`), how to check RP registrations and vCPU quota |
