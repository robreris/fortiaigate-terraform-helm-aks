# Supply your own web/API certificate

Terraform supports three web/API TLS sources: the generated deployment CA
(default), supplied PEM files, or Let's Encrypt. Supplied certificates and
Let's Encrypt are mutually exclusive.

In all three modes, PostgreSQL, Redis, guardrail services, logd, and license-manager use
`fortiaigate-internal-tls-secret`, signed by a generated deployment CA.
LLM gateway, API, webui, and the ingress listener use `fortiaigate-tls-secret`.
Database clients mount the internal secret separately and trust its `ca.crt`.
A supplied web certificate therefore does not need Kubernetes service names.

## Certificate inputs

Obtain these files from your certificate issuer:

- A PEM serving certificate chain: the leaf certificate first, followed by
  intermediate certificates in issuer order. The leaf must cover `ingress_host`
  and be valid for TLS server authentication. A matching wildcard is supported.
- The matching unencrypted PEM private key (PKCS#8, RSA, or EC).
- For a corporate/private CA, one PEM root CA certificate. Supply the public
  certificate only; Terraform never needs your issuer's private key.

Keep the files outside the repository. Their contents, including the serving
private key, are stored in Terraform state. Protect access to the state backend.
Relative file paths are resolved from the Terraform working directory.

Configure your local tfvars, for example:

```hcl
letsencrypt_enabled     = false
internal                = true
ingress_host           = "fortiaigate.example.com"
tls_certificate_path    = "/secure/certs/fortiaigate-fullchain.pem"
tls_private_key_path    = "/secure/certs/fortiaigate.key"
tls_ca_certificate_path = "/secure/certs/company-root-ca.pem"
```

Omit `tls_ca_certificate_path` for certificates issued by a publicly trusted CA.
Terraform checks input combinations, readable files, and PEM headers. Before
planning, validate the actual key pair, certificate chain, validity dates, server
purpose, and hostname with Python 3 and OpenSSL 3:

```bash
python3 scripts/check_tls.py \
  --certificate /secure/certs/fortiaigate-fullchain.pem \
  --private-key /secure/certs/fortiaigate.key \
  --hostname fortiaigate.example.com \
  --ca /secure/certs/company-root-ca.pem
```

For a public certificate, omit `--ca`; the command verifies against the local
system trust store. Then follow the README's infrastructure bootstrap and full
Terraform apply process. This validator is an explicit preflight command, not
an automatically executed Terraform hook.

## Application Gateway trust

The gateway presents the supplied certificate to browsers/API clients, and
LLM gateway/API/webui present the same certificate on the gateway's HTTPS backend
connections. Terraform sets both backend and health-probe hostnames to
`ingress_host` so the supplied certificate does not need `localhost` or internal
service names. Avoid overriding those annotations with a different hostname.
Per-service health-probe paths remain derived from each readiness probe.

For `internal=true`, Terraform uploads `tls_ca_certificate_path` as the gateway's
trusted root and adds the ingress trusted-root annotation. Publicly trusted
certificates need no custom root upload.

For `internal=false`, the AKS add-on owns the public gateway. Terraform does not
upload private roots to that gateway. Upload the supplied root certificate
manually using the process in [the gateway guide](application-gateway-dns-tls.md),
and set this ingress annotation to the uploaded root's name:

```hcl
ingress_annotations = {
  "appgw.ingress.kubernetes.io/appgw-trusted-root-certificate" = "company-root"
}
```

Browsers/API clients also need to trust your corporate root. Export it with
`terraform output -raw tls_ca_certificate` if supplied. That output is empty for
public certificates without a supplied root, and for Let's Encrypt.
`internal_tls_ca_certificate` exports the generated internal CA in every mode;
it is separate from web/API trust in supplied and Let's Encrypt modes.

Direct HTTPS connections to LLM gateway/API/webui must use a name covered by the supplied
certificate. An internal service DNS name will usually not match a public web
certificate. Direct clients of the other internal services use the generated CA.

## Renewal and upgrades

Build0047 targets fresh installations. Migration from older application schemas
and node-keyed licenses is unqualified; see [the compatibility audit](build0047-compatibility.md).
The TLS transition notes below do not establish application upgrade support.

Supplied certificates are not automatically renewed. Replace the PEM files,
rerun the validator, and plan/apply using the same paths. Terraform updates the
web secret and its certificate checksum rolls LLM gateway/API/webui. Changing only the
web certificate does not roll databases, guardrail services, logd, or license-manager.
Let's Encrypt continues to use cert-manager and Reloader for automatic renewals.

Existing generated CA/key/certificate resource addresses are retained. The new
internal secret initially uses the same generated material as an existing
private-CA deployment, so switching certificate source does not replace its
internal CA. Database pods and clients roll to mount the separate secret.

Upgrading an existing Let's Encrypt deployment re-enables database TLS. Schedule
an upgrade window: the app and database updates are not atomic, so connections
can fail while their settings differ. If Redis is already unhealthy and its
StatefulSet rollout stalls, inspect its logs and revisions; after the updated
StatefulSet is applied, recreating the Redis pod may be necessary. Review a saved
plan before applying. Test gateway backend health, browser/API access, Redis and
PostgreSQL connections, and certificate replacement in a disposable environment.
Offline checks do not establish compatibility with the runtime application images.
