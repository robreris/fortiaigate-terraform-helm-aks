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

- **PostgreSQL/Redis share the secret.** `helm.tf` points the bundled DBs at the
  same `fortiaigate-tls-secret` for their in-cluster TLS. They run in encrypt
  (not verify-CA) mode, so the hostname mismatch on a public cert is harmless. If
  you later enable strict CA verification for the DBs, give them a separate
  self-signed secret instead.
- **Renewal.** cert-manager renews ~30 days before expiry and rewrites the
  secret. The kubelet syncs the mounted file within ~1 min, but the app
  processes read the cert at startup — a future improvement is a reloader
  (e.g. Reloader, or a checksum wired off the secret) to restart pods on
  renewal. Not wired today.
- **The CRD-at-plan-time gotcha.** The `ClusterIssuer`/`Certificate` are shipped
  as a small local Helm chart (`certmanager-issuer/`) rather than a Terraform
  `kubernetes_manifest`, because the latter does a plan-time API dry-run that
  fails before the cert-manager CRDs exist.
- **Chart unchanged.** This is entirely Terraform-root + the issuer chart; the
  shared `fortiaigate/` chart is untouched, so it stays identical to the EKS
  stack.
