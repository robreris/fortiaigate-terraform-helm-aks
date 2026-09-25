# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo deploys

A single Terraform stack that stands up FortiAIGate on Azure AKS:

- Resource Group + VNet + AKS cluster + app/GPU node pools
- Azure Files storage account (required — the chart's shared PVC is `ReadWriteMany`, which Azure managed disks cannot satisfy)
- Application Gateway Ingress Controller (AGIC) addon (conditional)
- The local `fortiaigate/` Helm chart, based on the 8.0.1/build0031 archive with AKS-specific patches, which bundles Bitnami PostgreSQL and Redis subcharts

There is no application source code here — this repo is purely IaC. FortiAIGate container images come from an external registry referenced via `var.image_repository` (typically Azure Container Registry, e.g. `<name>.azurecr.io/fortiaigate`).

This repo is the Azure counterpart to `fortiaigate-terraform-helm-eks`. Its Helm chart carries AKS-specific ingress, TLS, license, storage, and GPU placement changes. Build0031 model configurations and application settings were aligned with the supplied `FAIG_helm_chart-V8.0.1-build0031-FORTINET.tar.gz` archive. Keep platform patches when importing later builds; do not replace the chart wholesale.

## Current state

The **8.0.0 chart** was deployed and validated end-to-end in a full clean rebuild on 2026-05-28: cluster (`fortiaigate-dev`, K8s 1.35) with one licensed app node (`max_pods` 110) + one A10 GPU node, all services running including Triton on the A10 and PostgreSQL on `managed-csi`. The 8.0.1/build0031 chart has passed offline rendering and configuration checks but still needs a live AKS rollout test. Licensing remains an operational caveat — see below.

For a **from-scratch deploy** (new subscription/operator), the sequence is:

1. Run the bootstrap in `docs/remote-state.md` to create the state storage account.
2. Run the checks in `docs/permissions-preflight.md` to confirm the SP has `Contributor` + `User Access Administrator` (or `Owner`).
3. If `gpu_enabled`, request A10/A100 quota in the target region first (defaults to 0) — see `docs/gpu-triton-compatibility.md`.
4. Do the two-step first apply (discover node names after step 1, set `var.licenses`, then full apply).

The user authenticates Terraform via service principal env vars: `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`.

**Licensing caveat (the one gotcha).** FortiAIGate node licenses can stick in a "License status: In Use" state — bound to a prior deployment whose nodes were torn down. `core` gates its readiness probe on a valid (not "in use") license, returning 503 until the seat frees, so the `helm_release`/`terraform apply` will time out waiting on `core` even though everything else is healthy. The seat auto-releases within ~24h of the old nodes disappearing (or release it manually in the FortiFlex/FortiCare portal). The same node-keyed licensing pins all pods to licensed nodes (see the "Node-keyed licensing pins ALL workload pods" note below), which is why `app_node_count` tracks the license count and `app_node_max_pods` is raised.

### Known open follow-ups

- **ACR pull role for kubelet identity — now codified (optional).** The AKS kubelet identity needs `AcrPull` on whichever ACR holds the FortiAIGate images, or every pod stalls in `ImagePullBackOff` (kubelet falls back to an anonymous token → 401) and the helm release / `terraform apply` hangs. `aks.tf` creates this grant via `azurerm_role_assignment.kubelet_acr_pull`, conditional on `var.acr_id`. Leave `acr_id` empty when the ACR (and its grant) is owned by another stack; set it to the ACR resource ID otherwise (the Terraform SP then needs role-assignment write on that scope). Note: each cluster recreate mints a NEW kubelet identity, so a one-off `az aks update --attach-acr` does not survive teardown — that's why codifying it matters.
- **AGIC health probes are per-backend via pod readiness probes — NOT a global `health-probe-path`.** The three ingress backends have different health endpoints (core `/fortiaigate/health/readiness`, api `/openapi.json`, webui `/ui` — the Next.js `basePath`, so `/` 404s). AGIC has no per-Service healthcheck-path annotation like the ALB, and a single ingress-wide `health-probe-path` annotation forces one path on all three (it 404/500s two of them, which only surfaces once a *trusted* backend cert lets the gateway actually probe — a self-signed/staging cert fails earlier on chain trust and masks it). So each backend pod carries an httpGet `readinessProbe` (added to `api.yaml`/`webui.yaml`; core already had one) and AGIC derives the probe from it. **Do not put `health-probe-path`/`health-probe-status-codes` in `var.ingress_annotations`.** This was a shared-chart change, mirrored to the EKS repo. `backend-protocol: https` and `ssl-redirect: true` are still set via annotations. Browser entry point is `/ui`, not `/`.
- **Workload Identity is now consumed by cert-manager (optional Let's Encrypt path).** `oidc_issuer_enabled` and `workload_identity_enabled` are on in `aks.tf` (the AKS analogue of EKS IRSA). The first consumer is `certmanager.tf`: when `var.letsencrypt_enabled = true`, a user-assigned identity federated to the cert-manager ServiceAccount (no secret) holds `DNS Zone Contributor` on an external Azure DNS zone, and cert-manager issues a browser-trusted cert into `fortiaigate-tls-secret` via ACME DNS-01. The azurefile-csi driver still authenticates via the storage account key path, not workload identity.

## Common commands

```bash
# Per-subscription init (switching subscriptions uses -reconfigure, NOT -migrate-state)
terraform init -backend-config=backends/<subscription>.hcl -reconfigure

# First-time deploy MUST be two-step — see "Two-step apply" below
terraform apply -target=azurerm_resource_group.this -target=azurerm_virtual_network.this -target=azurerm_subnet.aks -target=azurerm_subnet.appgw -target=azurerm_kubernetes_cluster.this -target=azurerm_kubernetes_cluster_node_pool.gpu -target=azurerm_role_assignment.agic_appgw_subnet_network_contributor -target=azurerm_role_assignment.kubelet_acr_pull -target=azurerm_role_assignment.agic_appgw_contributor -target=azurerm_role_assignment.agic_rg_reader -var-file=tfvars/<subscription>.tfvars
# (gpu pool / AGIC subnet grant / AcrPull grant are count-gated on gpu_enabled / agic_enabled / acr_id, and the AGIC gateway grants on internal = true; all resolve to zero when off, so they're safe to leave in.
#  The AGIC grant belongs in step 1: the addon creates the App Gateway as soon as the cluster exists and needs join rights on the appgw subnet.)
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

**PostgreSQL and Redis run on Azure Disk, not the shared Azure Files claim.** The chart's `values.yaml` defaults both Bitnami subcharts to `existingClaim: "fortiaigate-storage"` (the RWX SMB share), but PostgreSQL's `initdb` fails on SMB — it needs a data dir owned by the db user at 0700 with POSIX fsync/locking, which CIFS/SMB cannot provide, so the pod crashloops (exit 1) right before initdb. `local.db_storage_values` in `helm.tf` overrides both to dynamically-provisioned RWO disks via `var.db_storage_class` (default `managed-csi`). This platform-specific override stays in Terraform. Switching an *already-deployed* postgres/redis from `existingClaim` to a volumeClaimTemplate requires deleting the StatefulSets first (`volumeClaimTemplates` is immutable); safe pre-first-successful-init since there's no data.

**Terraform owns the PostgreSQL password, not the Helm release.** `helm.tf` generates `random_password.postgresql_user`/`postgresql_admin` and writes them to a `kubernetes_secret.postgresql` named `fortiaigate-postgresql` (the chart's default name, so api/core/logd need no template change); `local.db_auth_values` sets `postgresql.auth.existingSecret` so Bitnami stops generating one. Why: PostgreSQL bakes the password into its data dir at initdb, and the data PVC survives `helm uninstall` but a chart-generated Secret doesn't — so any uninstall/reinstall (e.g. clearing a stuck `pending-install` after a Ctrl-C'd apply) minted a new password against the old database and api/core/logd crashlooped on `password authentication failed`. The `random_password`s use `ignore_changes = all` because a regenerated value silently breaks an initialized DB; rotating requires `ALTER ROLE` in PostgreSQL too. The Secret carries `helm.sh/resource-policy: keep` so the upgrade that drops it from a pre-existing release's manifest doesn't delete it. **Adopting on an already-deployed cluster** (Secret created by Helm) needs imports BEFORE the first apply, or the create fails with "already exists" (and fresh random values land in state — `terraform state rm` them and import):
```bash
terraform import -var-file=tfvars/<sub>.tfvars random_password.postgresql_user  "$(kubectl -n fortiaigate get secret fortiaigate-postgresql -o jsonpath='{.data.password}' | base64 -d)"
terraform import -var-file=tfvars/<sub>.tfvars random_password.postgresql_admin "$(kubectl -n fortiaigate get secret fortiaigate-postgresql -o jsonpath='{.data.postgres-password}' | base64 -d)"
terraform import -var-file=tfvars/<sub>.tfvars kubernetes_secret.postgresql fortiaigate/fortiaigate-postgresql
```
The plan must then show only in-place updates to the Secret (metadata) and `helm_release.fortiaigate` — no `random_password` replacement, no pod rollouts.

**AGIC is enabled via the AKS addon, not a separate Helm release.** `azurerm_kubernetes_cluster.this.ingress_application_gateway` (conditional on `var.agic_enabled`) tells AKS to create and manage an Application Gateway in the `appgw` subnet. Disable it to use ingress-nginx or the web_app_routing addon instead. When AGIC is disabled, the ingress resource still gets created by the chart but stays without an address until an externally-managed controller picks it up.

**Two subnets are required, even when AGIC is off.** `network.tf` always creates both `aks` and `appgw` subnets so subnet IDs stay stable when AGIC is toggled. This avoids replacing the cluster's network config to add or remove AGIC later.

**Internal vs internet-facing Application Gateway — the `internal` switch changes who owns the gateway.** `internal = false`: the AGIC add-on creates a public-only gateway itself (greenfield, in the `MC_` RG) — the validated public path, unchanged. `internal = true` (requires `agic_enabled` + the AGIC ingress class; a `helm_release` precondition enforces it): `appgw.tf` creates the gateway in the cluster RG with a public frontend (v2 requires a public IP; nothing listens on it — the placeholder listener is on the private frontend) plus a static private frontend (`var.appgw_private_ip`, default `cidrhost(appgw_subnet_cidr, -2)` = `.254`), the add-on is pointed at it via `gateway_id` (`aks.tf` nulls `gateway_name`/`subnet_id` then), and the AGIC identity gets Contributor on the gateway + Reader on the cluster RG (AKS only auto-grants for gateways it creates). `local.internal_appgw_values` adds the `use-private-ip` annotation, placed *before* `ingress_annotation_values` so explicit user annotations still override. Why BYO gateway: the add-on's own gateway has no private frontend, and AGIC silently ignores a `use-private-ip` Ingress on such a gateway (`NoPrivateIP`). The gateway has `lifecycle.ignore_changes` on all AGIC-owned blocks (listeners, pools, rules, probes, certs, tags) — remove any of those and every apply reverts AGIC's config to placeholders. Flipping the switch on a live cluster re-points the add-on at a different gateway (old public one orphaned in `MC_`); choose at deploy time. Self-signed TLS works in internal mode: `tls.tf` signs the serving cert with a per-deployment CA, `appgw.tf` uploads it as trusted root `fortiaigate-ca` (Terraform-managed — deliberately NOT in `ignore_changes`; AGIC only references roots by name), and `local.appgw_trusted_root_values` adds the `appgw-trusted-root-certificate` annotation. Public mode's add-on gateway isn't Terraform-managed, so self-signed public mode still 502s — use LE there. Details: `docs/application-gateway-dns-tls.md`.

**TLS is generated at apply time** (`tls.tf`: a per-deployment CA signs the serving cert; `tls.crt` = leaf + CA chain because the chart uses `tls.crt` as the Redis/PostgreSQL CA bundle — verified with psql verify-full, redis-cli --tls and Python ssl) **by default, or Let's Encrypt via cert-manager when `var.letsencrypt_enabled = true`.** In the default path the cert's SHA256 is passed to the Helm release as `tls.existingSecretChecksum` so pod template annotations trigger a rollout when the cert is regenerated. When Let's Encrypt is enabled, `tls.tf`'s three resources resolve to zero (count) and cert-manager owns `fortiaigate-tls-secret` instead — the checksum then keys off `letsencrypt_environment` so flipping staging→production rolls the pods. Because the chart's ingress `spec.tls` references that same secret, AGIC serves it as the frontend listener cert AND trusts the HTTPS backend (well-known CA chain), which is what fixes the self-signed backend 502 (`The Intermediate certificate is missing from the backend server chain`). The `ClusterIssuer`/`Certificate` ship as a local `certmanager-issuer/` chart, not a `kubernetes_manifest`, to avoid the plan-time CRD dry-run failure. **Stakater Reloader handles the cert-change roll in LE mode** (`helm_release.reloader`, also gated on `letsencrypt_enabled`, scoped to the `fortiaigate` namespace via `watchGlobally=false`): the `existingSecretChecksum` keys off the *env string*, so the staging→production roll fires immediately while cert-manager's DNS-01 issuance lands ~2-3 min later — pods boot on the still-staging cert and AGIC 502s the backends. Reloader watches the secret and rolls the annotated `core`/`api`/`webui` Deployments (annotation gated on `tls.reloaderEnabled`, default false → EKS + self-signed unaffected) *when the cert actually changes*, closing that race and covering silent renewals. It has no finalizers/PVCs, so it needs no manual `helm uninstall` at teardown. Full walkthrough: `docs/tls-letsencrypt.md`.

**Helm values are composed by `concat()` of `yamlencode`'d locals in `helm.tf`.** Set blocks can't handle YAML lists (tolerations) or keys with dots/slashes (ingress annotations), so structured values go through `yamlencode`. Order matters — later entries win. Currently: `extra_values_files` → `gpu_values` → `db_storage_values` → `db_auth_values` → `internal_appgw_values` → `ingress_annotation_values` → `tls_values` → `db_tls_values` → `license_node_values`. When adding a new structured override, decide where it belongs in that precedence chain. (`db_tls_values` sits *after* `tls_values` so that, in Let's Encrypt mode, it can flip `postgresql.tls.enabled`/`redis.tls.enabled` to false — the bundled DBs can't use an ACME cert as their own CA; see `docs/tls-letsencrypt.md`.)

**Which tfvars changes reach a running deployment.** Every Helm-facing variable was traced end-to-end (Terraform-computed values → `helm template` → manifests) and lands where intended; `deployment.chartRevision` is deliberately unused by templates — it only forces a Helm upgrade when local chart files change. Pod rollouts happen via spec changes (images, strategy, placement) or checksums: `checksum/tls` (cert) and `checksum/license` (`license.checksum`, a digest of the `var.licenses` file contents — a ConfigMap edit alone never restarts license-manager). Three settings CANNOT change on a live release because Kubernetes fields are immutable, so the Helm upgrade fails: `db_storage_class` (StatefulSet `volumeClaimTemplates`), the shared PVC's StorageClass, and shrinking `storage_size` (growing is fine — the class allows expansion). Set those before first deploy or rebuild.

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
| `appgw.tf` | (internal = true only) Terraform-managed Application Gateway with static private frontend + its public IP, and the AGIC identity's Contributor/Reader grants |
| `storage.tf` | Azure Files storage account, kubelet role assignments, `azurefile-fortiaigate` StorageClass |
| `helm.tf` | `fortiaigate` namespace, NVIDIA device plugin, Stakater Reloader (LE-only), fortiaigate Helm release, value composition |
| `licenses.tf` | `fortiaigate-license-config` ConfigMap from `var.licenses` |
| `tls.tf` | Self-signed cert + `fortiaigate-tls-secret` (only when `letsencrypt_enabled = false`) |
| `certmanager.tf` | (optional) cert-manager install + workload-identity-federated UAMI + DNS Zone Contributor + ACME ClusterIssuer/Certificate, gated on `var.letsencrypt_enabled` |
| `certmanager-issuer/` | Local Helm chart holding the `ClusterIssuer` + `Certificate` (avoids the `kubernetes_manifest` plan-time CRD problem) |
| `providers.tf` | azurerm + azuread + helm + kubernetes providers (helm/kubernetes use the AKS-emitted kubeconfig) |
| `backend.tf` | Empty azurerm backend; values supplied via `-backend-config` |
| `outputs.tf` | Cluster name, kubectl command, storage account name, ingress address (data-source lookup of the ingress) |
| `docs/remote-state.md` | One-time per-subscription bootstrap: RG + Storage Account + container for the state blob, plus SP `Storage Blob Data Contributor` grant |
| `docs/permissions-preflight.md` | What roles the Terraform SP needs (`Contributor` + `User Access Administrator`, or `Owner`), how to check RP registrations and vCPU quota |
