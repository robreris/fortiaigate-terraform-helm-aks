# Container registry and image upload (Azure)

This stack expects the FortiAIGate container images to already exist in
a registry referenced by `var.image_repository` (e.g.
`<acrname>.azurecr.io/fortiaigate`). The Terraform here does **not**
create the registry or push the images — those are out-of-band one-time
operations, conventionally owned by whichever team manages the registry.
This doc covers both.

This is a **pure build-and-push workflow** — it does not require an AKS
cluster to exist yet, and is intended to run before the first
`terraform apply`. The one piece that does depend on a running cluster
(granting the kubelet identity `AcrPull`) is covered separately at the
end in [Later: grant `AcrPull` once the cluster exists](#later-grant-acrpull-once-the-cluster-exists).

## Where the registry lives

**Put the ACR in its own resource group.** Not in the cluster RG, and
not in the Terraform state RG. The recommended layout for this stack
is three resource groups per subscription:

| RG | What's in it | Lifecycle |
|----|--------------|-----------|
| `fortiaigate-tfstate` | Terraform state storage account + container | One-time bootstrap (see `docs/remote-state.md`). Never destroyed. Strict RBAC — state often contains secrets. |
| `fortiaigate-acr` | The ACR + all pushed images | Long-lived. Survives cluster rebuilds. `AcrPush` granted here to CI / dev principals. |
| `fortiaigate-<env>` (e.g. `-test`, `-dev`, `-prod`) | AKS + VNet + Azure Files + Application Gateway — everything `terraform apply` owns | Created and destroyed per environment. This is the only RG `terraform destroy` touches. |

Each RG has one clear job. `terraform destroy` only ever empties the
third, so state and images survive untouched.

**Do not put the ACR in the cluster RG.** It works at first, but the
first time you run `terraform destroy` it deletes the registry along
with all ~26 GB of pushed images. Re-pushing those is slow. Worse, if
the kubelet `AcrPull` grant references the old ACR resource ID and you
recreate the registry under the same name, the grant won't transfer —
you'll have to re-create it.

If you've already pushed into a shared RG, you don't need to re-push
to recover. Move the ACR to its own RG with `az resource move` (the
resource ID changes; the FQDN, images, and any `AcrPull` grants scoped
to the resource ID survive the move):

```bash
az group create -n fortiaigate-acr -l eastus
ACR_ID=$(az acr show -n "$ACR_NAME" -g <shared-rg> --query id -o tsv)
az resource move --destination-group fortiaigate-acr --ids "$ACR_ID"
```

The commands in the rest of this doc assume the registry lives in a
dedicated `$ACR_RG` separate from the cluster RG.

## Sizing the SKU

Total compressed footprint of the FortiAIGate image set is ~25.8 GB (v8.0.0).

| SKU | Included storage | Geo-replication | Private endpoints | Notes |
|-----|------------------|-----------------|-------------------|-------|
| Basic | 10 GB | No | No | **Too small** — image set won't fit |
| Standard | 100 GB | No | No | Fine for single-region dev/test |
| Premium | 500 GB | Yes | Yes | Required for private link, content trust, geo-replication |

For a private/internal deployment (`var.internal = true` on this stack)
Premium is usually the right choice so the registry can sit behind a
private endpoint in the same VNet. For a public-facing dev cluster,
Standard is enough.

## Variables to set

```bash
export LOCATION="eastus"
export ACR_RG="fortiaigate-acr"
export ACR_NAME="fortiaigateacr$(echo $ARM_SUBSCRIPTION_ID | tr -d '-' | tail -c 9)"
export ACR_SKU="Standard"     # or Premium
export IMAGE_PREFIX="fortiaigate"
export BUILD="build0024"      # source of the .tar archives
export TAG="V8.0.0-${BUILD}"
export TRITON_TAG="25.11-onnx-trt-agt"
export TRITON_MODELS_TAG="0.1.4"
```

Validate the ACR name (5-50 alphanumerics, globally unique):

```bash
echo "$ACR_NAME" | grep -E '^[a-zA-Z0-9]{5,50}$' && echo OK || echo "FIX NAME"
```

## Step 1 — Create the registry

```bash
# RG (skip if reusing an existing one)
az group create --name "$ACR_RG" --location "$LOCATION"

# Registry. Disable the admin user — we'll authenticate with AAD.
az acr create \
  --resource-group "$ACR_RG" \
  --name "$ACR_NAME" \
  --sku "$ACR_SKU" \
  --admin-enabled false
```

The registry FQDN is `${ACR_NAME}.azurecr.io`. The value you'll feed to
this stack's `var.image_repository` is
`${ACR_NAME}.azurecr.io/${IMAGE_PREFIX}` (e.g.
`fortiaigateacrXXXX.azurecr.io/fortiaigate`).

## Step 2 — Authenticate Docker to the registry

`az acr login` exchanges your AAD token for a short-lived registry
token and stores it in your local Docker keychain. No long-lived
credentials.

```bash
# As yourself (interactive AAD) or the Terraform SP
az acr login --name "$ACR_NAME"
```

For non-interactive shells (CI), authenticate as the SP and re-run
`az acr login` — the SP needs `AcrPush` on the registry scope to push:

```bash
az role assignment create \
  --assignee "$ARM_CLIENT_ID" \
  --role "AcrPush" \
  --scope "$(az acr show -n $ACR_NAME -g $ACR_RG --query id -o tsv)"
```

## Step 3 — Load and push the image archives

Image archives live in `../FortiAIGate/build0024/images/` (or
`build0021/images/` for the legacy single-node build). Each `.tar` is a
`docker save` of one image tagged with its original Fortinet JFrog path
(`dops-jfrog.fortinet-us.com/docker-fortiaigate-local/<name>:<tag>`).

The pattern for each image is `docker load → docker tag → docker push`:

```bash
export IMAGES_DIR="../FortiAIGate/${BUILD}/images"
export ACR_PREFIX="${ACR_NAME}.azurecr.io/${IMAGE_PREFIX}"
export SRC_PREFIX="dops-jfrog.fortinet-us.com/docker-fortiaigate-local"

# Versioned FortiAIGate images (api/core/webui/logd/license_manager/scanner)
for img in api core webui logd license_manager scanner; do
  docker load -i "${IMAGES_DIR}/FAIG_${img}-${TAG}-FORTINET.tar"
  docker tag  "${SRC_PREFIX}/${img}:${TAG}"  "${ACR_PREFIX}/${img}:${TAG}"
  docker push "${ACR_PREFIX}/${img}:${TAG}"
done

# Custom Triton (different tag scheme)
docker load -i "${IMAGES_DIR}/FAIG_custom-triton-${TAG}-FORTINET.tar"
docker tag  "${SRC_PREFIX}/custom-triton:${TRITON_TAG}"  "${ACR_PREFIX}/custom-triton:${TRITON_TAG}"
docker push "${ACR_PREFIX}/custom-triton:${TRITON_TAG}"

# Triton models repo (different tag scheme)
docker load -i "${IMAGES_DIR}/FAIG_triton-models-${TAG}-FORTINET.tar"
docker tag  "${SRC_PREFIX}/triton-models:${TRITON_MODELS_TAG}"  "${ACR_PREFIX}/triton-models:${TRITON_MODELS_TAG}"
docker push "${ACR_PREFIX}/triton-models:${TRITON_MODELS_TAG}"
```

Notes:

- The Triton tags (`25.11-onnx-trt-agt`, `0.1.4`) are independent of the
  FortiAIGate build version. They may drift between builds — verify by
  inspecting the loaded image tag after `docker load`.
- Each push of the larger archives (`custom-triton` ~9.7 GB, `scanner`
  ~5.7 GB, `triton-models` ~3.6 GB) will saturate your uplink. On a
  slow connection, run from an Azure VM in the same region as the ACR
  to push over the Azure backbone instead.
- ACR does not require pre-creating repositories — the path
  `fortiaigate/api` is created implicitly on the first push to it.

## Step 4 — Verify

List what's in the registry:

```bash
az acr repository list --name "$ACR_NAME" -o table

# For each repo, show the tags
for repo in api core webui logd license_manager scanner custom-triton triton-models; do
  echo "=== ${repo} ==="
  az acr repository show-tags --name "$ACR_NAME" --repository "${IMAGE_PREFIX}/${repo}" -o tsv
done
```

You should see all eight repos under `fortiaigate/` with the correct
tags. Then set the Terraform variable:

```hcl
# tfvars/dev.tfvars
image_repository = "fortiaigateacrXXXX.azurecr.io/fortiaigate"
```

## Alternative: `az acr import` instead of pull/load/push

If the source images are reachable from Azure (e.g. an accessible
JFrog mirror or another ACR), `az acr import` copies them
server-side without a local download:

```bash
az acr import \
  --name "$ACR_NAME" \
  --source "dops-jfrog.fortinet-us.com/docker-fortiaigate-local/api:${TAG}" \
  --image  "${IMAGE_PREFIX}/api:${TAG}" \
  --username "$JFROG_USER" --password "$JFROG_PASS"
```

This bypasses the local `docker load`/`docker push` round-trip
entirely and is the fastest path when the source is reachable. The
`.tar` archives in `../FortiAIGate/build0024/images/` are the
distribution mechanism for sites that can't reach Fortinet's registry
directly; if you have direct access, `az acr import` is preferable.

## Common failure modes

| Error | Likely cause | Fix |
|-------|--------------|-----|
| `unauthorized: authentication required` on `docker push` | `az acr login` token expired (3 hours) | Re-run `az acr login -n $ACR_NAME` |
| `denied: requested access to the resource is denied` | Principal lacks `AcrPush` | Step 2 — grant `AcrPush` on the registry scope |
| Pod stuck in `ImagePullBackOff` with `401 Unauthorized` from `*.azurecr.io` | Kubelet identity missing `AcrPull` | See [Later: grant `AcrPull` once the cluster exists](#later-grant-acrpull-once-the-cluster-exists), then `kubectl delete pod <name>` to retry |
| `MANIFEST_UNKNOWN` from kubelet | Tag mismatch — the chart's `image.tag` doesn't match what was pushed | Compare `kubectl describe pod` against `az acr repository show-tags` |
| `no space left on device` during push | Local Docker storage exhausted by the ~26 GB image set | `docker system prune -a` between pushes, or push from an Azure VM with a larger disk |
| Push hangs / very slow | Pushing over a residential link | Run from an Azure VM in the same region as the registry |

## What this stack does (and doesn't) consume from the registry

`helm.tf` passes `var.image_repository` straight through to the chart
as `global.image.repository`. Each subchart appends its image name
(`/api`, `/core`, `/scanner`, etc.) and uses tags from the chart's
`values.yaml` — currently `V8.0.0-build0024` for the FortiAIGate images
and `25.11-onnx-trt-agt` / `0.1.4` for Triton. If you push under
different tags, override them in `var.extra_values_files` rather than
editing the chart.

The bundled Bitnami PostgreSQL and Redis subcharts pull from Docker Hub
by default. If your cluster has no outbound internet, you'll need to
mirror those into ACR too and override `postgresql.image.registry` and
`redis.image.registry` in a values file — but that's beyond the scope
of this doc.

## Later: grant `AcrPull` once the cluster exists

This is the open follow-up called out in `CLAUDE.md`. It is **not part
of the build-and-push workflow** — defer it until after the first
`terraform apply` has created the AKS cluster (specifically the
targeted `azurerm_kubernetes_cluster.this` step of the two-step apply).
The AKS cluster uses a **user-assigned kubelet identity** distinct from
the cluster's control-plane identity, and that identity needs `AcrPull`
on the registry so nodes can pull images without per-pod
imagePullSecrets.

```bash
# Look up the kubelet identity's principal ID from the running cluster.
# Substitute the cluster RG / cluster name from your tfvars.
export AKS_RG="<cluster RG>"
export AKS_NAME="<cluster name>"

export KUBELET_OBJECT_ID=$(az aks show \
  --resource-group "$AKS_RG" \
  --name "$AKS_NAME" \
  --query "identityProfile.kubeletidentity.objectId" \
  -o tsv)

# Grant AcrPull on the registry scope only
az role assignment create \
  --assignee "$KUBELET_OBJECT_ID" \
  --role "AcrPull" \
  --scope "$(az acr show -n $ACR_NAME -g $ACR_RG --query id -o tsv)"
```

If the registry lives in a different subscription from the cluster, the
SP running this command needs `User Access Administrator` on the ACR's
subscription too.

The AKS docs also document a one-shot `az aks update --attach-acr`
shortcut. It does the same role assignment, but you have to give the
running principal more rights on the cluster, and the role grant
silently no-ops if the principal can't make it — so doing the explicit
`role assignment create` above is clearer. (And it works when the
registry and cluster are in different subscriptions, which
`--attach-acr` does not.)

Without this grant the chart will install but every pod will land in
`ImagePullBackOff`. If you're seeing that after `terraform apply`,
this is almost certainly why.
