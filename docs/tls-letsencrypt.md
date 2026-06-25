# Automated Let's Encrypt TLS (cert-manager + Azure DNS)

This is the production TLS path for the public UI. It replaces the self-signed
certificate from `tls.tf` with a browser-trusted Let's Encrypt certificate,
issued and renewed automatically by cert-manager.

## What it solves

One issued certificate, written to `fortiaigate-tls-secret`, covers two things
at once:

- **Frontend (browser) trust.** The chart's ingress emits `spec.tls` referencing
  that secret, which AGIC reads to set the Application Gateway listener
  certificate. A real cert means no browser warning.
- **Backend trust / the 502.** The FortiAIGate pods serve HTTPS natively using
  the same secret. Application Gateway validates the backend certificate chain;
  a self-signed cert has no trusted chain, so every backend is marked unhealthy
  and the gateway returns **502 Bad Gateway**. A Let's Encrypt cert is signed by
  a well-known CA and cert-manager writes the **full chain** into `tls.crt`, so
  Application Gateway trusts the backend with **no trusted-root upload and no
  extra annotation**.

## How it authenticates (no secrets)

cert-manager writes the ACME `_acme-challenge` TXT records into your Azure DNS
zone using **workload identity** — the cluster's OIDC issuer (already enabled in
`aks.tf`) federated to a user-assigned managed identity that holds
`DNS Zone Contributor` on the zone. Nothing in this flow stores a service
principal secret.

```
cert-manager SA  --(federated OIDC token)-->  user-assigned identity
                                                   |
                                          DNS Zone Contributor
                                                   v
                                          Azure DNS zone (TXT records)
```

## Prerequisites

1. A **public Azure DNS zone** that already resolves on the internet (e.g. one
   created by App Service Domains). See
   [application-gateway-dns-tls.md](application-gateway-dns-tls.md) for the DNS
   record setup.
2. `ingress_host` set to a name **in that zone** (e.g. `fortiaigate.example.com`)
   with an `A` record pointing at the Application Gateway public IP.
3. The Terraform principal needs **role-assignment write** (Owner or User Access
   Administrator) on the DNS zone's resource group — it grants cert-manager's
   identity `DNS Zone Contributor`. If it can't, create that one role assignment
   out of band and remove `azurerm_role_assignment.cert_manager_dns` from the
   plan.

## Enable it

In your tfvars:

```hcl
ingress_host            = "fortiaigate.example.com"  # must already exist in the zone
letsencrypt_enabled     = true
letsencrypt_environment = "staging"                  # start here
acme_email              = "you@example.com"
dns_zone_name           = "example.com"
dns_zone_resource_group = "dns-rg"
# cert_manager_version  = "v1.16.2"                  # override if needed
```

Apply:

```bash
terraform apply -var-file=tfvars/dev.tfvars
```

### Always validate on staging first

Let's Encrypt **production** has strict rate limits (e.g. 5 duplicate certs per
week). Leave `letsencrypt_environment = "staging"` until issuance works, then
flip to `"production"`.

What staging does and does **not** prove:

- **Proves:** cert-manager can solve the ACME DNS-01 challenge (workload identity
  → Azure DNS RBAC → TXT record) and the `Certificate` reaches `READY=True`.
- **Does NOT prove the 502 is fixed.** The staging root is not in any trust store
  — not the browser's, and **not Application Gateway's** well-known CA set. So on
  staging the browser still warns *and* the backend-health 502 persists, because
  the gateway still can't trust the backend cert. Both clear only on
  **production**, whose root (ISRG Root X1) is well-known.

So: confirm the cert issues on staging, then switch to production and re-verify
backend health + a clean `curl` (no `-k`). When you switch, `terraform apply`
again — the TLS checksum keys off the environment name, so the app pods roll to
pick up the newly issued cert.

## Verify

```bash
# 1. Issuer registered with the ACME server
kubectl get clusterissuer letsencrypt-staging -o wide      # READY should be True

# 2. Certificate issued (temporary self-signed appears first, then the real one)
kubectl get certificate -n fortiaigate                      # READY True when done
kubectl describe certificate fortiaigate-tls -n fortiaigate

# 3. If it's stuck, inspect the challenge (DNS-01 TXT propagation, RBAC, etc.)
kubectl get challenges -n fortiaigate
kubectl describe challenge -n fortiaigate

# 4. Application Gateway backend health should flip to Healthy
NODE_RG=$(az aks show -g "$(terraform output -raw resource_group_name)" \
  -n "$(terraform output -raw cluster_name)" --query nodeResourceGroup -o tsv)
az network application-gateway show-backend-health \
  -g "$NODE_RG" -n "$(terraform output -raw cluster_name)-appgw" \
  --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].health" -o tsv
```

Once on production, `curl https://fortiaigate.example.com` (no `-k`) should
succeed with a trusted chain.

## How it boots without a chicken-and-egg stall

The app pods mount `fortiaigate-tls-secret` at startup, but ACME DNS-01 issuance
takes a couple of minutes. The `Certificate` carries
`cert-manager.io/issue-temporary-certificate: "true"`, so cert-manager drops a
throwaway self-signed cert into the secret **immediately**; the pods boot, and
cert-manager swaps in the real cert when issuance completes.

## Notes and caveats

- **PostgreSQL/Redis CANNOT use the LE secret — `helm.tf` disables their TLS in
  LE mode.** The chart points every app pod's `REDIS_SSL_CA_CERTS` /
  `POSTGRES_SSL_CA_CERTS`, and redis's own probe (`certCAFilename: tls.crt`), at
  the serving cert *as its own CA* — valid only for a self-signed cert. An ACME
  leaf can't validate itself, so redis crashloops on `tlsv1 alert unknown ca` and
  app→DB TLS breaks. `local.db_tls_values` therefore sets
  `postgresql.tls.enabled=false` / `redis.tls.enabled=false` when
  `letsencrypt_enabled = true`. This is safe: node-keyed licensing pins postgres,
  redis, and all app pods onto the single licensed app node, so DB traffic never
  leaves it. The earlier "DBs share the secret, harmless" claim was **wrong** —
  redis's probe *does* verify the CA. (Keeping DB TLS *and* a public ingress cert
  is the "Option B" follow-up: give the DBs a separate self-signed secret — a
  chart change mirrored to EKS, not yet done.)
- **Flipping an already-running deploy from DB-TLS-on to off deadlocks the redis
  StatefulSet.** The old crashlooping redis pod never goes Ready, so the rolling
  update won't recreate it on the new (TLS-off) spec — `updateRevision` !=
  `currentRevision` and the apply hangs. One-time fix:
  `kubectl delete pod fortiaigate-redis-master-0 -n fortiaigate` forces
  recreation on the new revision. A **fresh** deploy (no pre-existing TLS redis
  pod) doesn't hit this.
- **Staging → production is a real two-apply step, and production can be flaky.**
  The staging root is untrusted by both browsers and Application Gateway, so the
  502 only clears on production. When you flip, watch for two production-side
  snags we hit: (1) a Let's Encrypt **production API incident** (503 on
  `new-nonce`/`new-account`) — confirm with `curl -m10
  https://acme-v02.api.letsencrypt.org/acme/new-nonce` (want `204`) and the LE
  status page before retrying, and **don't hammer it** (production rate limits
  have no override); (2) if registration half-completes during a 503, the issuer
  ends up `Ready=True` but with **no account key ID** ("No Key ID in JWS header"
  on every order). Recover with:
  `kubectl delete secret letsencrypt-production-account-key -n cert-manager`
  then `kubectl rollout restart deployment cert-manager -n cert-manager` for a
  clean re-registration. Without `cmctl`, clear a stuck issuance backoff by
  patching the Certificate status `Issuing=True` (`--subresource=status`).
- **Pods read the cert at startup — Stakater Reloader now rolls them on cert
  change (LE mode).** cert-manager rewrites the secret (renewal ~30 days out, or
  immediately on a staging→production flip) and the kubelet syncs the mounted file
  within ~1 min, but the app processes read the cert **at startup**, so they keep
  serving the old cert until restarted. The Helm `existingSecretChecksum` keys off
  the *environment name*, which made this worse than a no-op: a staging→production
  `terraform apply` fires the checksum roll **immediately**, but cert-manager
  doesn't finish the DNS-01 issuance for another ~2-3 min, so the pods come up
  reading the *staging* cert still in the secret and never re-read the production
  one that lands after — AGIC then 502s the backends ("intermediate certificate is
  not signed by a well-known CA"). An in-place *renewal* (same env) doesn't change
  the checksum at all, so it never rolled.

  Fix (implemented): when `letsencrypt_enabled`, `helm.tf` installs the **Stakater
  Reloader** controller (`helm_release.reloader`, scoped to the `fortiaigate`
  namespace via `reloader.watchGlobally=false`) and the chart annotates the
  core/api/webui Deployments with `secret.reloader.stakater.com/reload:
  fortiaigate-tls-secret` (gated on `tls.reloaderEnabled`, default false — so
  self-signed mode and the EKS root are unaffected). Reloader watches the secret
  and rolls those Deployments **when the cert actually lands**, closing the
  early-roll race and handling silent renewals automatically. The
  `existingSecretChecksum` roll stays as a backstop. (If you ever need to force it
  by hand: `kubectl rollout restart deployment core api webui -n fortiaigate`,
  but only after the secret shows the production issuer — `kubectl get secret
  fortiaigate-tls-secret -n fortiaigate -o jsonpath='{.data.tls\.crt}' | base64 -d
  | openssl x509 -noout -issuer`.)
- **The CRD-at-plan-time gotcha.** The `ClusterIssuer`/`Certificate` are shipped
  as a small local Helm chart (`certmanager-issuer/`) rather than a Terraform
  `kubernetes_manifest`, because the latter does a plan-time API dry-run that
  fails before the cert-manager CRDs exist.
- **Per-backend health probes (NOT a global `health-probe-path`).** Once the
  trusted cert made AGIC reach the backends, the probes failed on HTTP status
  because the three services have different health endpoints: core
  `/fortiaigate/health/readiness`, api `/openapi.json`, webui `/ui` (the Next.js
  `basePath` — `/` 404s by design). AGIC has no per-Service healthcheck-path
  annotation like the ALB, and a single ingress-wide `health-probe-path` can't fit
  all three — so each backend pod now carries an httpGet `readinessProbe` and AGIC
  derives the per-backend probe from it. **Do not set `health-probe-path` /
  `health-probe-status-codes` in `ingress_annotations`** (they override the
  per-backend probes globally). This DID touch the shared `fortiaigate/` chart
  (readiness probes added to `api.yaml`/`webui.yaml`); the change was mirrored to
  the EKS repo to keep the charts identical. Browser entry point is **`/ui`**, not
  `/`.

## Planned follow-up: Option B — keep DB TLS via a separate self-signed secret (AKS-only)

Status: **not implemented** (current behavior is DB-TLS-off in LE mode, above).
Decision: implement this **AKS-only** — the AKS `fortiaigate/` chart will
**intentionally diverge** from the EKS copy. The two charts are independent file
copies (no code coupling); "keep them identical" is a convention, and they
already differ in `templates/scanners.yaml`. When this lands, update the
"identical chart" language in `CLAUDE.md` so the divergence reads as deliberate.

**Goal:** restore in-cluster TLS for postgres/redis while the public ingress/app
serving cert stays Let's Encrypt — by splitting the DB role onto its own
self-signed secret (`fortiaigate-db-tls-secret`). A self-signed cert is its own
CA, so the chart's `certCAFilename: tls.crt` / `REDIS_SSL_CA_CERTS=.../tls.crt`
self-reference works again.

**Chart changes (`fortiaigate/`, backward-compatible):**
1. `values.yaml`: add `tls.dbExistingSecret` and `tls.dbMountPath`, **defaulting
   to** `tls.existingSecret` / `tls.mountPath`. With the defaults, self-signed
   mode is unchanged (one secret) — only LE mode overrides them.
2. The four DB-talking templates — `core.yaml`, `api.yaml`, `logd.yaml`,
   `license-manager.yaml` — repoint `REDIS_SSL_CERTFILE/KEYFILE/CA_CERTS` and
   `POSTGRES_SSL_*` from `{{ .Values.tls.mountPath }}` to
   `{{ .Values.tls.dbMountPath }}`, and add a second volume/volumeMount for the
   DB secret. (`webui.yaml` doesn't touch the DBs — leave it.)
3. Point the subcharts at the DB secret: `postgresql.tls.certificatesSecret` and
   `redis.tls.existingSecret` → `tls.dbExistingSecret`.

**Terraform changes (AKS root):**
4. `tls.tf`: make the self-signed cert + `kubernetes_secret` **always** created
   (today they're `count = 0` in LE mode) under the name `fortiaigate-db-tls-secret`.
   Give it SANs for the DB service names (`fortiaigate-postgresql`,
   `fortiaigate-redis-master`) as hygiene.
5. `helm.tf`: change `local.db_tls_values` — instead of disabling DB TLS in LE
   mode, **re-enable** `postgresql.tls`/`redis.tls`, set
   `tls.dbExistingSecret = "fortiaigate-db-tls-secret"` + `tls.dbMountPath`, and
   give the DB pods their own checksum (off the self-signed DB cert) so they roll
   when it regenerates, independent of the LE checksum.

**Verify first:** confirm the app verifies the DB **CA but not hostname** (the
pre-LE single-self-signed-cert state worked even though `CN=ingress_host` ≠ the DB
service names, which implies hostname verify is off). If strict hostname verify
turns out to be on, the DB cert needs the DB service-name SANs (step 4 covers it).

**Switch-over gotcha:** flipping a *running* cluster from DB-TLS-off back to on
re-triggers the redis StatefulSet rolling-update deadlock — plan a one-time
`kubectl delete pod fortiaigate-redis-master-0 -n fortiaigate` during the apply.

**Validate on staging** (`letsencrypt_environment = "staging"`) before production,
same as the main flow. Risk is low: the backward-compatible defaults mean a
mistake can't affect the self-signed path, and a DB-trust regression fails loudly
(redis crashloops on `tlsv1 alert unknown ca`).
