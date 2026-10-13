# Operations and upgrades

Use the [README](../README.md) for the two-step first deployment and teardown.
This guide covers troubleshooting and changes to an existing deployment.
Review a saved Terraform plan before applying upgrades, and follow
[the deployment test checklist](testing.md) in a disposable environment first.

For the build0031-to-build0047 transition, follow the
[8.0.1-to-8.0.2 upgrade guide](upgrade-8.0.1-to-8.0.2.md), including secret
adoption and the application migration prerequisites before any full apply.

## PostgreSQL credential ownership and adoption

Terraform owns `random_password.postgresql_user`,
`random_password.postgresql_admin`, and `kubernetes_secret.postgresql` in
`helm.tf`. The Secret is named `fortiaigate-postgresql`;
`local.db_auth_values` sets `postgresql.auth.existingSecret` so the chart uses it.

PostgreSQL stores passwords in its data directory at initialization. Its data
PVC can survive a Helm uninstall, while a chart-generated Secret may disappear.
Reinstalling with newly generated passwords against retained data causes
`password authentication failed` in API, LLM gateway, and logd. Terraform ownership
keeps the credential lifetime independent of the Helm release.

The password resources use `ignore_changes = all`. Rotating a password requires
coordinating the Secret with `ALTER ROLE` inside PostgreSQL. The Secret's
`helm.sh/resource-policy: keep` annotation protects it when an upgrade removes
the previously chart-owned Secret from the release manifest.

For an existing deployment whose Secret was created by Helm, import its current
passwords and Secret **before applying** the Terraform ownership change. Replace
the tfvars path and namespace below to match the deployment:

```bash
terraform import -var-file=tfvars/dev.tfvars random_password.postgresql_user "$(kubectl -n fortiaigate get secret fortiaigate-postgresql -o jsonpath='{.data.password}' | base64 -d)"
terraform import -var-file=tfvars/dev.tfvars random_password.postgresql_admin "$(kubectl -n fortiaigate get secret fortiaigate-postgresql -o jsonpath='{.data.postgres-password}' | base64 -d)"
terraform import -var-file=tfvars/dev.tfvars kubernetes_secret.postgresql fortiaigate/fortiaigate-postgresql
```

Run credential imports in a private terminal; the import IDs contain passwords.
If a failed apply already recorded newly generated password resources, first
back up state and inspect those entries. Remove only the incorrect
`random_password.postgresql_user` and `random_password.postgresql_admin` entries
from state before importing the live values. Do not remove the live database or
Secret. The credential-adoption plan should preserve both passwords and show
only the expected Secret metadata and Helm release updates. Investigate any
password replacement or unexpected pod rollout before applying.

## Deployment licensing

Build0047 uses a deployment license stored in PostgreSQL. Upload it through the
authenticated `POST /api/v1/admin/licenses` endpoint using the release's request
format. The chart deploys two license-manager replicas with preferred
anti-affinity; both may run on a single app node. No node-name/license-file map,
license ConfigMap, or license-manager DaemonSet is needed. The legacy Terraform
`licenses` variable rejects nonempty maps so old inputs cannot be silently ignored.

App services and databases select the AKS app pool. Triton/vLLM select the
GPU pool and tolerate its taint. Node replacement no longer requires re-keying
hostname licenses. Size pools for workload capacity and check deployment license
coverage against the actual GPU inventory after onboarding and changes.

Upgrades from node-keyed licensing require separately qualified conversion;
see [the build0047 audit](build0047-compatibility.md#existing-deployment-upgrades-remain-a-separate-milestone).

## Application encryption, CSRF, and Redis secrets

Terraform creates `fortiaigate-application` with `master-key` and
`csrf-secret-key`, plus `fortiaigate-redis` with `redis-password`. Their
`random_password` resources ignore configuration drift to avoid replacing keys
against retained data. API, LLM gateway, and guardrail share the encryption key;
the optional DP agent uses the same Secret when enabled outside this Terraform
port. Helm receives Secret names, not their contents.

Back up the encryption key with PostgreSQL. Losing it can make encrypted
credentials and response-vault data unreadable. Retain Terraform state and these
Secrets across a Helm uninstall/reinstall. Creating a fresh Terraform state
against old application data is not a supported restore procedure. Existing
Redis/chart keys must be adopted through a qualified migration rather than
replaced with new values. Do not rotate the master key without an application
migration procedure.

## Storage and immutable settings

The shared PVC requires ReadWriteMany and uses Azure Files. PostgreSQL and Redis
use dedicated ReadWriteOnce Azure Disks through `local.db_storage_values` in
`helm.tf` and `var.db_storage_class` (default `managed-csi`). PostgreSQL's data
directory needs permissions, locking, and filesystem behavior that the shared
SMB claim cannot provide; using it can fail during `initdb`.

Changing a database StatefulSet from an existing claim to a volume claim
template, or changing `db_storage_class`, requires a planned StatefulSet and
data migration because `volumeClaimTemplates` is immutable. Before the first
successful database initialization, recreation may be sufficient; populated
deployments require backup and restore or migration. Do not delete data PVCs
as a troubleshooting shortcut.

The shared PVC's StorageClass cannot be changed in place, and its requested
size cannot be shrunk. Expansion is supported by the configured StorageClass.
Choose storage settings before deploying, or plan a migration.

`local.storage_account_name` derives a lowercase alphanumeric name from
`cluster_name` plus a random suffix, truncated to 24 characters. Changing
`cluster_name` can change that name and cause storage account replacement.
The suffix resource has no cluster-name keeper. Inspect replacement plans and
migrate shares before replacing an account that contains data. The StorageClass
uses `Retain`, but destroying the account still removes its shares; see
[README teardown](../README.md#teardown).

## Helm value precedence and rollouts

`helm.tf` merges extra values files first, then app/GPU placement, application
secret references, database storage/authentication, private gateway, gateway
trusted root, ingress annotations, and TLS. Later entries take precedence;
Terraform `set` blocks override the merged values. Check the actual `values =
concat(...)` and `set` blocks when adding overrides.

`deployment.chartRevision` is a chart digest that forces Helm to notice local
chart edits; templates do not use it to restart pods. Pod rollouts follow pod
spec changes or checksums for web TLS, internal TLS, and model configuration.
Web certificate replacement rolls LLM gateway/API/webui without rolling databases,
guardrail services, logd, or license-manager. Let's Encrypt renewals use Reloader.
See [supplied TLS upgrade notes](tls-supplied.md#renewal-and-upgrades) for the
separate internal Secret and the database TLS transition.

Keep `gpu_driver = "Install"` explicit in `aks.tf`. Omitting it has previously
caused a provider plan to replace the GPU pool, disrupting model availability.
Investigate unexpected node-pool replacement on every upgrade plan.

## Recovering a partial bootstrap

If a failed first apply left networking incomplete and AKS reports subnet
validation errors, inspect the failed resources and finish the subnet targets
before retrying the README bootstrap:

```bash
terraform apply -target=azurerm_subnet.aks -target=azurerm_subnet.appgw -var-file=tfvars/dev.tfvars
```

Both subnet resources are kept even when AGIC is disabled so toggling ingress
does not require adding or removing subnet references. For gateway ownership,
AGIC-managed blocks, and backend readiness probes, use
[the gateway guide](application-gateway-dns-tls.md) and
[Let's Encrypt troubleshooting](tls-letsencrypt.md#notes-and-caveats).
