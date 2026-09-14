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
with all pushed images. Re-pushing those is slow. Worse, if
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

The eight supplied build0031 Docker archives total 21.29 GB
(19.83 GiB) on disk. This is the size of the supplied tar files, not a measured
ACR storage bill: it stores layers differently from Docker tar archives.
Monitor usage after import and review [Azure's current SKU limits](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-skus)
before choosing a tier.

| SKU | Included storage | Geo-replication | Private endpoints | Notes |
|-----|------------------|-----------------|-------------------|-------|
| Basic | 10 GiB | No | No | Storage beyond the included amount is billed; lower throughput |
| Standard | 100 GiB | No | No | Fine for single-region dev/test |
| Premium | 500 GiB | Yes | Yes | Required for private link and geo-replication |

For a private/internal deployment (`var.internal = true` on this stack)
Premium is usually the right choice so the registry can sit behind a
private endpoint in the same VNet. For a public-facing dev cluster,
Standard is enough.

## Variables to set

```bash
export LOCATION="westus"
export ACR_RG="fortiaigate-acr"
export ACR_NAME="fortiaigateacr$(echo $ARM_SUBSCRIPTION_ID | tr -d '-' | tail -c 9)"
export ACR_SKU="Standard"     # or Premium
export IMAGE_PREFIX="fortiaigate"
export BUILD="build0031"      # supplied image archives and Helm chart
export TAG="V8.0.1-${BUILD}"
export TRITON_TAG="25.11-onnx-trt-agt-s1"
export TRITON_MODELS_TAG="0.1.6-s1"
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

The eight image archives and
`FAIG_helm_chart-V8.0.1-build0031-FORTINET.tar.gz` should be downloaded to a preferred location.

The deployment chart requires these repositories under `IMAGE_PREFIX`:

| Repository | Tag for build0031 | Used by |
|------------|-------------------|---------|
| `api`, `core`, `webui`, `logd`, `license_manager`, `scanner` | `V8.0.1-build0031` | Application services |
| `custom-triton` | `25.11-onnx-trt-agt-s1` | Triton server, when GPU is enabled |
| `triton-models` | `0.1.6-s1` | Triton model loader, when GPU is enabled |

All eight archive manifests use the source repository prefix
`dops-jfrog.fortinet-us.com/docker-fortiaigate-local` with the names and tags
above. The extracted Helm chart renders those same eight references when its
application repository is set. Its bundled PostgreSQL and Redis images are
listed separately below.

This AKS chart now uses the extracted 8.0.1/build0031 model configuration and
application settings while retaining AKS-specific GPU placement, ingress,
license/TLS ownership, and storage behavior. The upstream archive is therefore
still **not** a direct drop-in replacement. Image and offline chart checks do
not establish runtime compatibility until a live AKS deployment is tested.

The pattern for each image is `docker load → docker tag → docker push`:

```bash
export IMAGES_DIR="<location where images downloaded"
export ACR_PREFIX="${ACR_NAME}.azurecr.io/${IMAGE_PREFIX}"

# Stop before any push if the verified archives are missing.
for img in api core webui logd license_manager scanner custom-triton triton-models; do
  test -f "${IMAGES_DIR}/FAIG_${img}-${TAG}-FORTINET.tar" || {
    echo "Missing ${IMAGES_DIR}/FAIG_${img}-${TAG}-FORTINET.tar; check the supplied archive names" >&2
    exit 1
  }
done

# docker load prints the image's embedded source reference. Check its name and
# tag before retagging it for ACR.
push_archive() {
  local name="$1" dest_tag="$2" archive loaded source_image
  archive="${IMAGES_DIR}/FAIG_${name}-${TAG}-FORTINET.tar"
  loaded="$(docker load -i "$archive")" || return
  printf '%s\n' "$loaded"
  source_image="$(printf '%s\n' "$loaded" | sed -n 's/^Loaded image: //p')"
  if [[ -z "$source_image" || "$source_image" == *$'\n'* ]]; then
    echo "Expected one tagged image in $archive; inspect docker load output" >&2
    return 1
  fi
  if [[ "${source_image##*/}" != "${name}:${dest_tag}" ]]; then
    echo "Unexpected source image $source_image in $archive" >&2
    return 1
  fi
  docker tag "$source_image" "${ACR_PREFIX}/${name}:${dest_tag}" || return
  docker push "${ACR_PREFIX}/${name}:${dest_tag}"
}

# Versioned FortiAIGate images (api/core/webui/logd/license_manager/scanner)
for img in api core webui logd license_manager scanner; do
  push_archive "$img" "$TAG" || exit 1
done

# Custom Triton (different tag scheme)
push_archive custom-triton "$TRITON_TAG" || exit 1

# Triton models repo (different tag scheme)
push_archive triton-models "$TRITON_MODELS_TAG" || exit 1
```

Notes:

- Triton tags are independent of the application tag. Check the loaded image
  references and match all three Terraform tag variables to the pushed tags.
- These archives may be large. On a slow connection, run from an Azure VM in
  the same region as the ACR to push over the Azure backbone instead.
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

You should see all eight repos under `fortiaigate/` with the exact tags in the
table above. Set the Terraform variables to the same image set:

```hcl
# tfvars/dev.tfvars
image_repository = "fortiaigateacrXXXX.azurecr.io/fortiaigate"
image_tag                = "V8.0.1-build0031"
triton_image_tag         = "25.11-onnx-trt-agt-s1"
triton_models_image_tag  = "0.1.6-s1"
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
`.tar` archives, when supplied, are the distribution mechanism for sites
that cannot reach Fortinet's registry directly. If you have direct access,
`az acr import` is an alternative. The eight archive manifests confirm the
JFrog source prefix and tags in this example; direct source-registry access
still depends on your credentials and network path.

## Common failure modes

| Error | Likely cause | Fix |
|-------|--------------|-----|
| `unauthorized: authentication required` on `docker push` | `az acr login` token expired (3 hours) | Re-run `az acr login -n $ACR_NAME` |
| `denied: requested access to the resource is denied` | Principal lacks `AcrPush` | Step 2 — grant `AcrPush` on the registry scope |
| Pod stuck in `ImagePullBackOff` with `401 Unauthorized` from `*.azurecr.io` | Kubelet identity missing `AcrPull` | See [Later: grant `AcrPull` once the cluster exists](#later-grant-acrpull-once-the-cluster-exists), then `kubectl delete pod <name>` to retry |
| `MANIFEST_UNKNOWN` from kubelet | Tag mismatch — the chart's `image.tag` doesn't match what was pushed | Compare `kubectl describe pod` against `az acr repository show-tags` |
| `no space left on device` during push | Local Docker storage exhausted by the image set | Use a larger Docker data disk or push from an Azure VM with sufficient space |
| Push hangs / very slow | Pushing over a residential link | Run from an Azure VM in the same region as the registry |

## What this stack does (and doesn't) consume from the registry

`helm.tf` passes `var.image_repository` to `fortiaigate.image.repository`.
The chart appends each image name (`/api`, `/core`, `/scanner`, etc.). Set
`image_tag` for the application images, `triton_image_tag` for `custom-triton`,
and `triton_models_image_tag` for `triton-models` in your tfvars. Their defaults
are `V8.0.1-build0031`, `25.11-onnx-trt-agt-s1`, and `0.1.6-s1`, respectively.
The defaults now select build0031; set all three variables explicitly for
later builds. Terraform `set` blocks
take precedence over `extra_values_files` for these image settings.

The eight FortiAIGate repositories are not the complete set of images pulled
by AKS. With the bundled databases enabled, the current chart also renders
`docker.io/bitnamilegacy/postgresql:17.4.0-debian-12-r19`,
`docker.io/bitnamilegacy/redis:8.2.0-debian-12-r0`, and
`docker.io/bitnamilegacy/os-shell:12-debian-12-r50` (PostgreSQL init container).
These are not in the FortiAIGate archive set. The optional NVIDIA device
plugin, cert-manager, and Reloader Helm releases pull further images from their
own chart defaults. For a network-restricted cluster, mirror those images and
set the corresponding subchart/release image values before deployment.

## Later: grant `AcrPull` once the cluster exists

This is **not part of the build-and-push workflow** — the cluster identity
does not exist until after the targeted AKS bootstrap apply. Set `acr_id` in
tfvars to let Terraform create the `AcrPull` grant during the full apply. Use
the manual commands below only when that grant is managed outside this stack.
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
