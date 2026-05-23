# Remote state bootstrap (Azure)

Terraform stores its state in an Azure Storage Account blob. This is a
**one-time, per-subscription** setup — once the storage account exists, every
future `terraform init` for this stack just points at it via
`-backend-config=backends/<subscription>.hcl`.

Unlike AWS, you do **not** need a separate lock table. The azurerm backend
uses native blob leases for state locking.

## What this creates

| Resource | Purpose |
|----------|---------|
| Resource Group | Holds the state storage account. Conventionally separate from the application RG so you can destroy the app stack without nuking state. |
| Storage Account | Globally unique. Holds the state blob. Versioning enabled so a corrupt `apply` can be rolled back. |
| Blob Container | Holds the state blob (`fortiaigate-aks.tfstate` by default). |

## Variables to choose

Set these once in your shell before running the commands below. Pick a
deterministic suffix (last 4 chars of the subscription ID is a common
convention) — the storage account name must be globally unique and 3-24
lowercase alphanumerics.

```bash
export LOCATION="eastus"
export STATE_RG="fortiaigate-tfstate"
export STATE_SA="fortiaigatetf$(echo $ARM_SUBSCRIPTION_ID | tr -d '-' | tail -c 9)"
export STATE_CONTAINER="tfstate"
```

Verify the account name is valid (must match `^[a-z0-9]{3,24}$`):

```bash
echo "$STATE_SA" | grep -E '^[a-z0-9]{3,24}$' && echo OK || echo "FIX NAME"
```

## Bootstrap commands

Run these as a principal that has **Owner** (or **Contributor** + **Storage
Account Contributor**) on the target subscription. The Terraform service
principal does **not** need to be the one running these — bootstrap is a
human-driven one-shot.

```bash
# 1. Log in (interactive — the SP that Terraform uses comes later)
az login
az account set --subscription "$ARM_SUBSCRIPTION_ID"

# 2. Register required resource providers (idempotent; no-op if already done)
az provider register --namespace Microsoft.Storage --wait
az provider register --namespace Microsoft.ContainerService --wait
az provider register --namespace Microsoft.Network --wait
az provider register --namespace Microsoft.OperationalInsights --wait

# 3. Resource group for state
az group create \
  --name "$STATE_RG" \
  --location "$LOCATION"

# 4. Storage account. TLS 1.2 enforced; public blob access off; versioning on.
az storage account create \
  --resource-group "$STATE_RG" \
  --name "$STATE_SA" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false

az storage account blob-service-properties update \
  --resource-group "$STATE_RG" \
  --account-name "$STATE_SA" \
  --enable-versioning true \
  --enable-delete-retention true \
  --delete-retention-days 30

# 5. Container for the state blob
az storage container create \
  --account-name "$STATE_SA" \
  --name "$STATE_CONTAINER" \
  --auth-mode login
```

## Grant the Terraform SP access to the state container

The SP you'll use to run `terraform apply` (`ARM_CLIENT_ID`) needs
**Storage Blob Data Contributor** on the state storage account so it can
read/write the state blob and acquire leases for locking.

```bash
az role assignment create \
  --assignee "$ARM_CLIENT_ID" \
  --role "Storage Blob Data Contributor" \
  --scope "$(az storage account show -n $STATE_SA -g $STATE_RG --query id -o tsv)"
```

If you'd rather use the storage account access key (legacy, simpler but less
auditable), skip the role assignment and set:

```bash
export ARM_USE_AZUREAD=false
export ARM_ACCESS_KEY="$(az storage account keys list -g $STATE_RG -n $STATE_SA --query '[0].value' -o tsv)"
```

The default (`ARM_USE_AZUREAD=true`) uses the SP's AAD identity for the
blob operations — recommended.

## Write the backend config file

```bash
cat > backends/dev.hcl <<EOF
resource_group_name  = "$STATE_RG"
storage_account_name = "$STATE_SA"
container_name       = "$STATE_CONTAINER"
key                  = "fortiaigate-aks.tfstate"
use_azuread_auth     = true
EOF
```

`use_azuread_auth = true` tells the backend to use the SP's AAD identity
(set via `ARM_*` env vars) instead of a storage account key. This is what
the role assignment above grants.

## Verify it works

```bash
# Switch shell to the Terraform SP
az login --service-principal \
  -u "$ARM_CLIENT_ID" \
  -p "$ARM_CLIENT_SECRET" \
  --tenant "$ARM_TENANT_ID"
az account set --subscription "$ARM_SUBSCRIPTION_ID"

# Init against the new backend
terraform init -backend-config=backends/dev.hcl -reconfigure
```

If init succeeds you should see `Successfully configured the backend
"azurerm"!` and a fresh `.terraform/terraform.tfstate` pointing at the
remote blob.

## Common errors

| Error | Cause | Fix |
|-------|-------|-----|
| `AuthorizationFailed` on `BlobLease` | SP missing `Storage Blob Data Contributor` | Re-run the `az role assignment create` above, wait ~60s for propagation |
| `The storage account named ... is already taken` | Name not globally unique | Change `STATE_SA` suffix |
| `Blob is currently leased` on every plan | Previous run crashed mid-apply, lease never released | `az storage blob lease break --container-name $STATE_CONTAINER --account-name $STATE_SA --blob-name fortiaigate-aks.tfstate --lease-break-period 0` |
| `ResourceProviderNotRegistered` | Step 2 skipped | Run the `az provider register` commands |

## Switching subscriptions

Each subscription gets its own backend config under `backends/`:

```bash
cp backends/dev.hcl backends/prod.hcl
# Edit prod.hcl to point at the prod subscription's storage account
terraform init -backend-config=backends/prod.hcl -reconfigure
```

`-reconfigure` (not `-migrate-state`) — you don't want to copy dev state
into prod's container.
