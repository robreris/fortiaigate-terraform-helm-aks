# Upgrade from 8.0.1/build0031 to 8.0.2/build0047

This guide compares `main` at `a55c506` (8.0.1/build0031) with `v8.0.2` at
`559875c` (8.0.2/build0047), inspected on 2026-10-12. It describes configuration
changes and a staged upgrade procedure for an existing AKS deployment.

**A populated-cluster upgrade is not yet qualified.** The repository contains
infrastructure and charts, not application migration code. Neither the chart
nor identical database dependency versions establish support for upgrading an
8.0.1 database. Obtain Fortinet's build0031-to-build0047 schema/data migration,
license conversion, and credential migration instructions, then rehearse them
against restored data before applying to a production deployment. No live
upgrade was performed while writing this guide.

## What changes

| Area | 8.0.1 on `main` | 8.0.2 on `v8.0.2` | Operator action |
| --- | --- | --- | --- |
| Application/chart | `8.0.1`, `V8.0.1-build0031` | `8.0.2`, `V8.0.2-build0047` | Use the complete AKS chart and Terraform changes, not just a new application tag |
| Data plane | `core` and eight scanner Deployments | `llm-gateway`, `guardrail`, `dlp-scanner`, `policy-guard` | Re-map detector configuration and validate client behavior; old services are removed |
| Licensing | Node-keyed files, Terraform ConfigMap, license-manager DaemonSet | Deployment license stored in PostgreSQL, two license-manager Deployment replicas | Arrange a compatible deployment license and vendor conversion procedure; remove the node-license map |
| Placement | Licensed hostname affinity | App-pool selectors, GPU-pool selectors and taint tolerations | Keep existing pools; size for workloads rather than the number of licensed hostnames |
| Inference | Triton and `triton-models` | Triton plus vLLM and `faig-models` | Upload the new image set and explicitly choose shared/dedicated GPU topology |
| Ingress | `/` to core; `/api/` to API; `/ui` to webui | `/ai` to LLM gateway; `/` and `/ui` to webui; `/api/` to API | Update LLM client URLs/integrations and gateway probes; preserve `/ai` when forwarding |
| Secrets | Terraform PostgreSQL credentials; Helm Redis/CSRF secrets | Terraform also owns Redis, CSRF, and a credential encryption master key | Adopt existing secret values before the full apply; resolve application encryption migration with Fortinet |
| TLS | Existing generated/supplied/ACME web TLS plus internal TLS | Same ownership model, new internal service SANs | Expect internal serving certificate reissuance and dependent pod restarts; preserve CA/private-key resources |
| Databases/storage | PostgreSQL/Redis Azure Disks; shared Azure Files | Same backing and dependency versions | Preserve state, credentials, PVC identities, storage classes, and sizes; application schema compatibility still needs qualification |
| Optional agent | No DP agent | DP-agent chart exists but Terraform forces it off | Do not enable it as an assumed migration runner; its image is absent from the supplied bundle |

The old scanner names are `language`, `code`, `promptinjection`, `sensitive`,
`toxicity`, `anonymize`, `deanonymize`, and `customrule`. There is no demonstrated
one-to-one conversion from their settings to build0047 DLP/POLICY detectors.

PostgreSQL chart `16.7.0`, Redis chart `22.0.0`, `Chart.lock`, the Terraform
provider lockfile, and `storage.tf` are unchanged between the compared tips.
Database pod placement/configuration changes still cause rollouts. The shared
PVC template is unchanged; labels reflect the new chart version.

## 1. Establish a recoverable starting point

On the running 8.0.1 deployment, record the exact Git commit, backend config,
subscription, tfvars, extra Helm values, image tags, AKS version, pool sizes,
ingress address, and Helm revision. Confirm the selected kubeconfig points to
the intended cluster. Use its actual namespace/release names; examples below
assume the default `fortiaigate` release and namespace.

Keep these records and backups in protected storage outside Git:

- A state backup with `terraform state pull`, including PostgreSQL passwords,
  storage identity/suffix, and TLS keys. Retain the original remote backend.
- A consistent PostgreSQL backup and a tested restore, including application
  and license-related data. Follow the application's quiesce/backup guidance.
- Redis persistent data and its live password, plus a tested restore. Do not
  flush Redis or assume its session/application data is disposable.
- Shared Azure Files contents, existing PVC/PV bindings, and disk/share IDs.
- Live Kubernetes Secrets, old license ConfigMap/files and license-manager key,
  effective Helm values, and release manifests/history. These contain secrets.

For example, after setting `UPGRADE_DIR` to a protected directory outside the
repository:

```bash
umask 077
terraform state pull > "$UPGRADE_DIR/pre-upgrade.tfstate"
helm history fortiaigate -n fortiaigate > "$UPGRADE_DIR/helm-history.txt"
helm get values fortiaigate -n fortiaigate --all > "$UPGRADE_DIR/helm-values.yaml"
helm get manifest fortiaigate -n fortiaigate > "$UPGRADE_DIR/helm-manifest.yaml"
kubectl -n fortiaigate get secrets -o yaml > "$UPGRADE_DIR/secrets.yaml"
kubectl -n fortiaigate get configmap fortiaigate-license-config -o yaml > "$UPGRADE_DIR/node-licenses.yaml"
kubectl -n fortiaigate get pvc -o yaml > "$UPGRADE_DIR/pvcs.yaml"
```

Skip the ConfigMap export only if the deployment has no node-license ConfigMap.
These exports are configuration backups, **not database or file-data backups**.
Avoid shell tracing and sharing raw state, manifests, or plans.

Keep the old ACR images available. A rebuild with fresh state against retained
data is not an upgrade or a supported restore. Do not run `terraform destroy`,
uninstall the release, or delete PVCs to prepare for this upgrade.

## 2. Rehearse the application migration separately

Restore backups into an isolated test environment, with a separate backend and
separate database disks/shares. Do not point rehearsal at production storage.
Arrange test licensing with Fortinet to avoid conflicting license use.

Get answers to these release-specific questions before proceeding:

1. Is direct build0031-to-build0047 migration supported? Which binary/tool runs
   schema migrations, at what stage, and with what downtime and rollback limits?
2. How are users, organizations, provider credentials, response-vault data,
   policies/detectors, logs, and Redis state migrated or re-created?
3. Does credential conversion require an existing encryption key? If none
   existed, how are legacy stored credentials converted to the new key format?
4. How is a node license converted/reissued as a deployment license, and when
   can the new license be uploaded relative to service startup/readiness?
5. Are DLP/POLICY coverage and simultaneous Triton/vLLM execution supported on
   the chosen Azure GPU/runtime configuration?

The DP-agent values mention startup migrations, but this Terraform port disables
that agent. No repository script establishes a supported database migration or
license conversion. Perform the vendor's steps in rehearsal and record results
using [the testing guide](testing.md). If migration support is unavailable,
qualify a separate fresh 8.0.2 installation and vendor-supported export/import
instead of applying the new chart to the old database.

## 3. Prepare images and deployment inputs

Upload all ten build0047 images to the existing ACR prefix using
[the registry guide](registry-and-images.md). `core`, the old `scanner` image,
and `triton-models` are not the new service/model set. Retain old images for
recovery and check AKS pull access before the maintenance window.

Edit a copy of the deployment's actual tfvars; do not replace it wholesale with
the new example. Set the four independent tags explicitly:

```hcl
image_tag               = "V8.0.2-build0047"
triton_image_tag        = "25.11-onnx-trt-agt-rpt-s1"
triton_models_image_tag = "0.0.4-s1"
vllm_image_tag          = "0.28.0-rpt-s1"

# Example only: choose and qualify a supported inference layout.
gpu_enabled     = true
vllm_gpu_attach = "shared"
gpu_node_count  = 1

# Remove the old node-name-to-license-file entries.
licenses = {}
```

Dedicated mode uses separate Triton and vLLM GPU allocations. At the defaults,
plan at least two one-GPU nodes (`vllm_gpu_attach = "dedicated"`,
`gpu_node_count = 2`) and obtain quota before increasing capacity. Shared mode
runs both engines in one pod and needs live AKS NVIDIA device/runtime and VRAM
qualification. Keeping the A10 SKU does not prove it can run the combined load.
CPU-only disables vLLM; POLICY detectors fail closed. See
[GPU compatibility](gpu-triton-compatibility.md).

Preserve `cluster_name`, resource group, namespace, network IDs/CIDRs, ingress
mode/hostname, TLS mode/paths, PostgreSQL/Redis storage settings, and the state
backend. Do not combine the application upgrade with an AKS version change,
network ownership change, node resize, storage migration, or certificate-mode
change. Keep `gpu_driver = "Install"` and consider rollout headroom; the default
`update_strategy = "Recreate"` deliberately permits downtime on constrained GPUs.

Review each `extra_values_files` entry:

- Replace obsolete `core`, `scanners`, `global.licenses`, `license.*`, and
  `license_manager.placement` customization with appropriate `llmGateway`,
  `guardrail`, `triton`, `vllm`, and app-pool settings. Old keys can be accepted
  by Helm while having no effect.
- Review changed resources, replica counts, model/detector settings, Redis
  memory/persistence configuration, failure policies, and outbound provider
  behavior. Do not copy old Redis configuration blindly over new defaults.
- Remove global AGIC health-probe-path overrides and global path rewrites.
  Gateway/API/webui readiness endpoints differ; `/ai` must arrive unchanged.
- Preserve required application settings, but resolve inline CSRF settings as
  part of secret adoption below. Review SSO's public URL if SAML is used.

Terraform merges extra values first, then managed settings, and its `set` blocks
win last. Editing chart defaults or supplying a different existing-secret name
in extra values does not override Terraform's secret/placement configuration.
See [operations](operations.md#helm-value-precedence-and-rollouts).

## 4. Adopt live secrets before the full application apply

Switch the working checkout to the reviewed 8.0.2 commit and initialize against
**the same environment backend**:

```bash
terraform init -backend-config=backends/dev.hcl -reconfigure -lockfile=readonly
terraform state list
```

Use the deployment's actual file paths. Do not migrate state to a new backend
or run `init -upgrade` as an incidental part of this upgrade. Ensure obsolete
`licenses` entries are removed so build0047 validation can run.

### PostgreSQL

The resource addresses `random_password.postgresql_user`,
`random_password.postgresql_admin`, and `kubernetes_secret.postgresql` are stable.
A deployment using current `main` should already have them in state. Confirm
they agree with the working database; no new passwords should be generated.
Older installations must complete [PostgreSQL credential adoption](operations.md#postgresql-credential-ownership-and-adoption)
first. Never import new random passwords over an initialized database.

### Redis

8.0.1 normally has a Helm-owned `fortiaigate-redis` Secret containing
`redis-password`. 8.0.2 assigns that same Secret name to Terraform and points the
Redis subchart at `auth.existingSecret`. Import its live password and Secret
before any full apply:

```bash
terraform import -var-file=tfvars/dev.tfvars random_password.redis "$(kubectl -n fortiaigate get secret fortiaigate-redis -o jsonpath='{.data.redis-password}' | base64 -d)"
terraform import -var-file=tfvars/dev.tfvars kubernetes_secret.redis fortiaigate/fortiaigate-redis
```

These commands assume neither address is already managed. Check first; if a
previous attempt created different values, reconcile them with the live values
and state backup before continuing. Imports expose secret values as process
arguments; run them only in a private administrative environment without tracing.
Verify the source key is present/nonempty before importing. For customized
secret names/password sources, use the live source used by the running pods.

Stage a reviewed targeted plan for the imported Redis Secret:

```bash
terraform plan -var-file=tfvars/dev.tfvars \
  -target=kubernetes_secret.redis -out="$UPGRADE_DIR/redis-adoption.tfplan"
terraform apply "$UPGRADE_DIR/redis-adoption.tfplan"
```

This must preserve the password and add `helm.sh/resource-policy: keep` to the
**live** Secret before Helm removes its old chart-owned Secret from the release
manifest. Import alone does not apply that annotation. Do not proceed if this
plan changes the password, touches the Helm release, or replaces infrastructure.
The full upgrade must retain the same Secret and use the same password in all
clients. Never use a Redis password reset as a migration shortcut.

### CSRF and credential encryption

8.0.1 normally has `fortiaigate-csrf` with key `csrf-secret-key`, or a configured
inline `fortiaigate.env.csrfSecretKey`. 8.0.2 puts that value and the master key
in the new Terraform-owned `fortiaigate-application` Secret. For the default
Secret-backed configuration, adopt the current CSRF value:

```bash
terraform import -var-file=tfvars/dev.tfvars random_password.csrf "$(kubectl -n fortiaigate get secret fortiaigate-csrf -o jsonpath='{.data.csrf-secret-key}' | base64 -d)"
```

If CSRF is configured inline, import that effective value privately instead;
then remove the inline setting so API/gateway use Terraform's Secret. Inline
CSRF takes precedence even when an existing Secret is configured. Removing the
old chart CSRF Secret is expected only after its live value has been captured
and the new Secret has been staged. Account for reauthentication during cutover.

Stock `main` has no application master-key resource/template. That does not
prove a customized deployment or its data has no encryption key. Establish
which key the retained credentials/data require with Fortinet. If one exists,
import that exact value into `random_password.application_master_key` before
creating the new application Secret. Do not substitute the old
`fortiaigate-license-manager` `license-key`: it served the old license system
and is not evidence of an application credential encryption key.

Generate a new application master key only if the qualified migration procedure
permits it. New key creation alone does not convert legacy encrypted/plaintext
credentials. Stage `kubernetes_secret.application` with a reviewed targeted plan
after resolving both values. Import that Secret too if it already exists;
otherwise Terraform creates it. After resolving/importing the key and CSRF
value, use the same review process:

```bash
terraform plan -var-file=tfvars/dev.tfvars \
  -target=kubernetes_secret.application -out="$UPGRADE_DIR/application-adoption.tfplan"
terraform apply "$UPGRADE_DIR/application-adoption.tfplan"
```

The plan should create/update only the intended application Secret and its
password dependencies, preserving imported values. It must not upgrade Helm
or replace existing database/TLS credentials. Back up the resulting key with
the database.

All three new password resources ignore configuration drift, but that does not
make an incorrect first value safe. Once data uses the key, never recreate it or
regenerate it against retained data. Targeted secret preparation is a deliberate
one-time adoption step; return to full plans for the release upgrade.

## 5. Review the full plan and perform the rehearsed cutover

With the qualified migration/backup procedure ready and secrets adopted:

```bash
terraform plan -var-file=tfvars/dev.tfvars -out="$UPGRADE_DIR/upgrade.tfplan"
terraform show "$UPGRADE_DIR/upgrade.tfplan"
```

Keep the plan protected. Expected changes include:

- An in-place update of `helm_release.fortiaigate` to the new chart/image set.
- Removal of `kubernetes_config_map.licenses[0]` if the old map existed.
- Addition of the new secret/password resources only where they were not
  imported/staged, with no replacement of adopted credentials.
- Reissued internal serving certificates for new service SANs, Secret updates,
  and database/application pod rollouts. Generated web TLS changes too when it
  uses the same generated serving certificate; supplied/ACME web TLS keeps its
  separate ownership. CA and private-key resources should remain stable.
- GPU capacity changes only if explicitly selected. Managed-network moved
  declarations preserve earlier singleton VNet/subnet addresses as `[0]`.
  Both compared branches already contain those declarations. `main` also has
  additional guards/tests for incomplete existing-network inputs that are not
  present at the compared 8.0.2 tip; preserve complete, valid existing IDs and
  do not treat that difference as a network migration requirement.

Stop and investigate any AKS/VNet/subnet/gateway/storage-account/database
replacement, PVC identity or storage-class change, PostgreSQL/Redis password
change, master-key replacement, or unexpected license deletion outside the
retired node-license ConfigMap. Terraform's plan represents Helm as a release
update; it does not enumerate all Kubernetes changes or prove schema safety.

Representative offline renders show Helm removes core/the eight old scanners,
changes license-manager from DaemonSet to Deployment, and removes the old CSRF
and Redis Secrets from chart ownership. Shared inference replaces the
`triton-server` Deployment with `triton-vllm-server`; dedicated inference keeps
Triton and adds vLLM. The Triton Service name remains usable, but endpoints
change. API/webui/logd and database workload identities remain in the chart.
Compare the actual effective values with the new render before cutover.

During the rehearsed maintenance window, stop/quiesce writes and traffic as
required by the vendor procedure, take the final consistent backups, perform
migration steps in their specified order, and apply the reviewed plan:

```bash
terraform apply "$UPGRADE_DIR/upgrade.tfplan"
```

An existing cluster normally needs a full apply, not the first-install bootstrap.
If GPU capacity must be provisioned in advance, review and apply that targeted
infrastructure change separately, then create a fresh full plan. Regenerate any
saved plan after state changes; do not apply an old plan after imports or other
applies.

Upload/convert the deployment license using the authenticated
`POST /api/v1/admin/licenses` endpoint at the point specified by the rehearsed
procedure. Use Fortinet's documented request body/authentication; this repo
does not define a conversion tool or reliable license upload payload. Remove
node-license discovery from ongoing operations after successful conversion.

## 6. Verify before resuming traffic

Check pods, ingress, PVCs, and events, then test application behavior:

```bash
kubectl -n fortiaigate get pods,pvc,ingress
kubectl -n fortiaigate get deployment,statefulset,daemonset
kubectl -n fortiaigate get events --sort-by=.lastTimestamp
terraform plan -var-file=tfvars/dev.tfvars
```

Confirm:

- Databases mount the original disks, shared files are accessible, and both
  database credentials and adopted Redis credentials still work.
- API/webui, license-manager, gateway, and guardrail services are ready, and
  internal TLS trust works across API/gateway/guardrail/license-manager/database
  connections. AGIC reports healthy HTTPS backends.
- `/ui` and `/api/` work; real LLM traffic reaches `/ai` with its path intact.
  Existing integrations have been updated for the new endpoint contract.
- Users/organizations, provider credentials, policies, logs, SSO where used,
  and encrypted data are preserved according to the migration contract.
- The deployment license is valid for actual GPU inventory, models decrypt/load,
  GPU placement/device visibility is correct, and DLP plus POLICY requests
  complete under realistic simultaneous load. Ready pods alone are insufficient.
- Old core/scanner workloads and the license-manager DaemonSet are retired, no
  hostname-license affinity remains, and the next plan has no unexplained
  replacements or recurring credential changes.

Record region, AKS/GPU configuration, exact commits/tags, migration steps,
license conversion, downtime, tests, and recovery results in
[the testing guide](testing.md). Until these checks pass, retain the maintenance
window and the pre-upgrade recovery point.

## Recovery

A Helm rollback changes Kubernetes resources; it does not reverse database
schema changes, recover deleted data, restore Terraform-managed node-license
ConfigMaps, or restore earlier credential ownership automatically. A failed
Terraform/Helm apply can leave a partially changed environment. Keep traffic
quiesced while inspecting it, and do not blindly retry or recreate Secrets.

Use the recovery procedure established in rehearsal: restore compatible
PostgreSQL/Redis/shared-file data and the matching secrets/keys, use the recorded
8.0.1 code and images, reconcile Terraform's current state with actual resources,
and restore node-license wiring/coverage if returning to 8.0.1. Reconcile Redis
ownership so Helm and Terraform do not compete. Review the recovery plan before
applying it. Restoring an old Terraform state blob alone does not undo Azure or
Kubernetes changes and can orphan newly created resources.

## Evidence and limits

The comparison used direct branch-tip diffs of Terraform, chart templates,
values, and lockfiles, plus offline Helm renders with the vendored subcharts in
shared and dedicated GPU modes. Those representative renders showed no
selector changes for surviving Deployment/StatefulSet objects; they do not
establish admission against the actual installed workload specifications.
No application images were executed, database migrations tested, license
conversion performed, or Azure resources contacted. See
[the build0047 compatibility audit](build0047-compatibility.md) for release
archive evidence and remaining runtime qualification work.
