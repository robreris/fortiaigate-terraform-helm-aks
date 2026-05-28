# Permissions pre-flight check (Azure)

Run these checks **before** your first `terraform apply` to confirm the
service principal in `ARM_CLIENT_ID` / `ARM_CLIENT_SECRET` /
`ARM_TENANT_ID` / `ARM_SUBSCRIPTION_ID` can actually provision everything
this stack creates.

## What this stack creates (and what permissions each needs)

| Resource | Provider | Permission needed |
|----------|----------|-------------------|
| Resource Group | `Microsoft.Resources` | `Contributor` on subscription **or** `Owner` |
| VNet + subnets | `Microsoft.Network` | `Network Contributor` (covered by `Contributor`) |
| AKS cluster | `Microsoft.ContainerService` | `Contributor` |
| AKS-managed Application Gateway (AGIC addon) | `Microsoft.Network` | `Contributor` on the AppGw subnet's RG. AKS creates a managed identity and assigns it `Contributor` on the gateway — that role assignment requires `User Access Administrator` (or `Role Based Access Control Administrator`) on the parent scope. |
| Storage Account + role assignments | `Microsoft.Storage` + `Microsoft.Authorization` | `Contributor` for the SA itself, plus `User Access Administrator` / `Role Based Access Control Administrator` to grant the kubelet identity `Storage Account Contributor` and `Storage File Data SMB Share Contributor`. |
| Workload Identity / OIDC | `Microsoft.ContainerService` | Covered by `Contributor`. No AAD app creation is performed by this stack (yet), so no AAD permissions are required for the initial deploy. |

**Bottom line:** the SP needs **`Contributor` + `User Access Administrator`** on the target subscription (or RG), or just **`Owner`**. `Contributor` alone is **not** enough — it cannot create the role assignments in `storage.tf`.

## Step 1 — Log in as the SP

```bash
az login --service-principal \
  -u "$ARM_CLIENT_ID" \
  -p "$ARM_CLIENT_SECRET" \
  --tenant "$ARM_TENANT_ID"
az account set --subscription "$ARM_SUBSCRIPTION_ID"

# Sanity: confirm you're who you think you are
az account show -o table
```

## Step 2 — Inspect the SP's role assignments

```bash
az role assignment list \
  --assignee "$ARM_CLIENT_ID" \
  --subscription "$ARM_SUBSCRIPTION_ID" \
  --all \
  -o table
```

Look for these `roleDefinitionName` values, scoped at the subscription or
the RG you intend to deploy into:

- `Owner` (sufficient on its own), **OR**
- `Contributor` **AND** (`User Access Administrator` or `Role Based Access Control Administrator`)

If you see only `Contributor`, role assignments inside `storage.tf` will
fail with `AuthorizationFailed` partway through the apply. Grant the
missing role first:

```bash
# Grant UAA on the subscription (least-privilege option)
az role assignment create \
  --assignee "$ARM_CLIENT_ID" \
  --role "User Access Administrator" \
  --scope "/subscriptions/$ARM_SUBSCRIPTION_ID"
```

## Step 3 — Confirm resource providers are registered

AKS, Application Gateway, and the file CSI driver all need their RPs
registered in the subscription. Registration is per-subscription, not
per-RG.

```bash
for rp in Microsoft.ContainerService Microsoft.Network Microsoft.Storage \
          Microsoft.OperationalInsights Microsoft.ContainerRegistry \
          Microsoft.ManagedIdentity; do
  state=$(az provider show -n "$rp" --query registrationState -o tsv)
  printf "%-40s %s\n" "$rp" "$state"
done
```

Any row that prints `NotRegistered` needs:

```bash
az provider register --namespace <name> --wait
```

`--wait` blocks until registration completes (a few minutes the first time).
The SP needs `Contributor` to call `register`; if it doesn't have that yet,
an admin must run this step.

## Step 4 — Check quotas

The defaults in `variables.tf` need vCPU quota in the target region:

- `Standard_D16s_v5` × `app_node_count` (app pool, default 1) — 16 vCPU each in the **Standard DSv5 Family**
- `Standard_NV36ads_A10_v5` × 1 (GPU pool, if `gpu_enabled = true`) — 36 vCPU in the **Standard NVADSA10v5 Family**. NOTE: A10/A100 GPU families default to **0** quota in most regions and are request-only — see `docs/gpu-triton-compatibility.md`.

```bash
# Print all quota lines that are near or at the cap
az vm list-usage \
  --location "$(grep '^location' tfvars/dev.tfvars 2>/dev/null | awk -F\" '{print $2}')" \
  --query "[?currentValue >= localName && limit < \`100\`].[localName, currentValue, limit]" \
  -o table

# Or just the families this stack cares about
az vm list-usage --location eastus -o table | \
  grep -E "(Total Regional|DSv5|NVADSA10v5)"
```

GPU quota (`Standard NVADSA10v5 Family vCPUs` for the default A10 SKU) is
**0 by default** in most subscriptions. If you need GPU support, file a quota
request *before* the first apply — it usually takes 1-2 business days. See
`docs/gpu-triton-compatibility.md` for the exact family and amount.

## Step 5 — Dry-run with `terraform plan`

After steps 1-4 pass, the most authoritative check is a real plan:

```bash
terraform init -backend-config=backends/dev.hcl -reconfigure
terraform plan -var-file=tfvars/dev.tfvars
```

A clean plan means the SP can at least *read* every resource type. It does
**not** prove the SP can *create* them — only the apply will. Run a small
test apply first if you're unsure (e.g. only the resource group):

```bash
terraform apply -target=azurerm_resource_group.this -var-file=tfvars/dev.tfvars
```

If that succeeds, the SP has the baseline `Contributor` rights. Then
target the cluster:

```bash
terraform apply \
  -target=azurerm_resource_group.this \
  -target=azurerm_virtual_network.this \
  -target=azurerm_subnet.aks \
  -target=azurerm_subnet.appgw \
  -target=azurerm_kubernetes_cluster.this \
  -var-file=tfvars/dev.tfvars
```

If that succeeds, the remaining apply (`terraform apply -var-file=...`)
exercises the role-assignment paths and the helm/kubernetes providers. A
failure there with `AuthorizationFailed` on a role assignment is the
classic sign you need `User Access Administrator`.

## Common failure modes

| Error message | Likely cause | Fix |
|---------------|--------------|-----|
| `AuthorizationFailed` creating `Microsoft.Authorization/roleAssignments` | SP missing UAA / RBAC Admin | Step 2 — grant UAA |
| `MissingSubscriptionRegistration` | RP not registered | Step 3 — `az provider register` |
| `QuotaExceeded` / `OperationNotAllowed` on node pool | vCPU quota too low for region/family | Step 4 — request quota |
| `Insufficient privileges to complete the operation` (AAD) | Future Workload Identity work that creates AAD apps would need `Directory.Read.All` or `Application.ReadWrite.OwnedBy`. Not required for the current stack. | N/A today |
| AKS create fails with `subnet ... not found` | Two-step apply skipped (subnets weren't created first) | See README "Two-step apply" |
