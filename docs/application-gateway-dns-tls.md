# Application Gateway, DNS, and TLS

This stack's Azure equivalent of the AWS `ALB + Route 53 + ACM` pattern is:

| AWS | Azure |
|-----|-------|
| Application Load Balancer | Application Gateway managed by AGIC |
| Route 53 hosted zone | Azure DNS zone, or whichever DNS provider owns the zone |
| Route 53 alias/A record | `A` record pointing at the Application Gateway public IP |
| ACM certificate | Kubernetes TLS secret, cert-manager-managed secret, or an Application Gateway SSL certificate |

## Public UI flow

For an internet-reachable FortiAIGate UI, configure the ingress values with
a public Application Gateway frontend and a hostname:

```hcl
agic_enabled  = true
ingress_class = "azure-application-gateway"
internal      = false
ingress_host  = "fortiaigate.example.com"
```

Apply the stack:

```bash
terraform apply -var-file=tfvars/dev.tfvars
```

Then find the Application Gateway address:

```bash
terraform output ingress_address

# If the ingress status has not populated yet, query the AKS managed resource group.
NODE_RG=$(az aks show \
  --resource-group "$(terraform output -raw resource_group_name)" \
  --name "$(terraform output -raw cluster_name)" \
  --query nodeResourceGroup \
  -o tsv)

az network public-ip list \
  --resource-group "$NODE_RG" \
  --query "[].{name:name,ip:ipAddress,dns:dnsSettings.fqdn}" \
  -o table
```

Create DNS for `ingress_host`:

- **Azure DNS:** create an `A` record in the DNS zone that points to the
  Application Gateway public IP.
- **External DNS provider:** create the same `A` record wherever the zone is
  hosted.

Example Azure DNS record:

```bash
DNS_RG="<dns-zone-resource-group>"
DNS_ZONE="example.com"
APPGW_IP="<application-gateway-public-ip>"

az network dns record-set a create \
  --resource-group "$DNS_RG" \
  --zone-name "$DNS_ZONE" \
  --name "fortiaigate" \
  --ttl 300

az network dns record-set a add-record \
  --resource-group "$DNS_RG" \
  --zone-name "$DNS_ZONE" \
  --record-set-name "fortiaigate" \
  --ipv4-address "$APPGW_IP"
```

Azure DNS does not have a direct Route 53-style ALB alias record. The normal
pattern is an `A` record (or an Azure DNS **alias** A record targeting the public
IP *resource*) to the Application Gateway public IP. If you configure a DNS label
on the public IP, a `CNAME` to that label is also possible.

> **Pick the right public IP.** The AKS managed resource group contains **two**
> public IPs and they look interchangeable in the alias-record dropdown:
> - `<cluster>-appgw-appgwpip` — the Application Gateway **frontend**. This is the
>   one to target.
> - a **GUID-named** IP — the cluster's **outbound load-balancer** (node egress).
>   Pointing DNS here routes nowhere useful.
>
> Confirm by matching the IP from `terraform output ingress_address`.

> **The IP changes on a teardown/rebuild.** The Application Gateway and its public
> IP live in the AKS-managed `MC_...` resource group, so a full `terraform
> destroy` + rebuild mints a **new** IP. The DNS zone and domain registration
> survive (they're in your own RG), so recovery is just re-pointing the record —
> not re-registering. After a rebuild, get the new IP and update the record:
>
> ```bash
> terraform output ingress_address   # new Application Gateway IP
> az network dns record-set a update \
>   --resource-group "$DNS_RG" --zone-name "$DNS_ZONE" --name "fortiaigate" ...
> ```
>
> An Azure DNS **alias** A record pointed at the public IP *resource* (rather than
> a hardcoded address) auto-follows the IP, but only while that resource exists —
> a rebuild replaces it, so you re-point either way.

## TLS options

By default the stack creates `fortiaigate-tls-secret` in `tls.tf` from a
certificate signed by a Terraform-generated, per-deployment CA. In internal mode
that CA is uploaded to the gateway as a trusted root, so the gateway reaches
the backends without a 502 (see [TLS](#tls) under internal access). In public
mode it isn't uploaded, and browsers won't trust the CA in either mode.

For production, use one of these patterns:

1. Replace the Terraform-generated TLS material with a real certificate for
   `ingress_host` and keep using the Kubernetes TLS secret referenced by the
   Ingress `spec.tls`.
2. Manage the Kubernetes TLS secret with cert-manager and Let's Encrypt. This is
   automated by the stack behind `letsencrypt_enabled = true`: cert-manager
   issues a browser-trusted cert into `fortiaigate-tls-secret` via ACME DNS-01
   against an Azure DNS zone (workload-identity auth), and `tls.tf` steps aside
   so Terraform no longer owns the secret. This also makes AGIC trust the HTTPS
   backend automatically (well-known CA chain), so no trusted-root upload is
   needed. Full walkthrough: [docs/tls-letsencrypt.md](tls-letsencrypt.md).
3. Install a certificate on Application Gateway and reference it with:

   ```hcl
   ingress_annotations = {
     "appgw.ingress.kubernetes.io/appgw-ssl-certificate" = "<appgw-cert-name>"
   }
   ```

   AGIC ignores `appgw-ssl-certificate` when the Ingress also defines
   `spec.tls`. The chart currently emits `spec.tls` when `tls.enabled = true`,
   so this option needs a chart/values change before it becomes the primary
   frontend certificate path.

## Internal/private access

### Checklist

1. **Choose the mode before the first deploy.** Set `internal = true` in the
   tfvars before step 1. Flipping it on a running cluster moves AGIC to a
   different gateway (see [Switching an existing cluster](#switching-an-existing-cluster)).
2. **Network path.** Clients must reach this stack's VNet (`vnet_cidr`,
   default `10.0.0.0/16`) through VNet peering, VPN, or ExpressRoute. The
   stack does not create that connectivity. Make sure `vnet_cidr` doesn't
   overlap the networks it will be connected to.
3. **DNS.** After the deploy, point `ingress_host` at
   `terraform output appgw_private_ip` in the DNS your clients use (see [DNS](#dns)).
4. **TLS.** Works out of the box: the default certificate is signed by a
   per-deployment CA that Terraform uploads to the gateway as a trusted root.
   To remove the browser warning, distribute
   `terraform output -raw tls_ca_certificate` to client trust stores, or use
   Let's Encrypt (see [TLS](#tls)).
5. **Verify.** After the full apply:

   ```bash
   kubectl get ingress -n fortiaigate            # ADDRESS = the private IP (10.0.64.254 by default)
   kubectl describe ingress fortiaigate-ingress -n fortiaigate | tail -n 20
   ```

   The ingress events must not contain `NoPrivateIP` (the gateway has no
   private frontend) or authorization errors (AGIC is missing its role grants).
   From a machine on the connected network, run
   `curl -k https://<ingress_host>/ui`. It should return the UI once TLS and
   DNS are in place.

Set `internal = true` (with `agic_enabled = true` and
`ingress_class = "azure-application-gateway"`) **before the first deploy**:

```hcl
agic_enabled  = true
ingress_class = "azure-application-gateway"
internal      = true
ingress_host  = "fortiaigate.corp.example.com"
# appgw_private_ip = "10.0.64.254"   # default: second-to-last address of appgw_subnet_cidr
```

### What the switch changes

| | `internal = false` | `internal = true` |
|---|---|---|
| Who creates the Application Gateway | The AGIC add-on (greenfield), in the `MC_...` node resource group | Terraform (`appgw.tf`), in the cluster resource group; the add-on is pointed at it via `gateway_id` |
| Frontends | Public only | Public (required by App Gateway v2, **no listener bound**) + static private (`appgw_private_ip`) |
| Ingress annotation | — | `appgw.ingress.kubernetes.io/use-private-ip: "true"` |
| Listeners bound to | Public IP | Private IP only |
| AGIC identity roles | Network Contributor on the appgw subnet | Same, plus Contributor on the gateway and Reader on the cluster resource group |
| Reachable from | Internet | The VNet and anything connected to it (peering, VPN, ExpressRoute) |

The add-on's own gateway cannot be used for internal mode: it has only a public
frontend, and AGIC ignores an Ingress annotated `use-private-ip` on a gateway
without a private frontend (`NoPrivateIP` warning in the ingress events and
AGIC log).

After AGIC takes over, Terraform ignores the gateway's routing configuration
(listeners, pools, rules, certificates, probes, tags) so applies don't revert
what AGIC wrote. The placeholder listener Terraform creates is bound to the
private frontend, so nothing is ever served on the public IP.

Find the address to publish in DNS:

```bash
terraform output appgw_private_ip
kubectl get ingress -n fortiaigate
```

### DNS

The private IP is stable for the life of the gateway and, because it is
configured rather than allocated, identical across teardown/rebuilds with the
same `appgw_private_ip`. Point `ingress_host` at it in whichever DNS your
clients use:

- **Corporate DNS** — an `A` record in the internal zone. Most common for
  on-prem clients over VPN/ExpressRoute.
- **Azure Private DNS zone** linked to the VNet(s) clients resolve from (or to
  a hub VNet with a DNS Private Resolver that on-prem forwards to).
- **Public Azure DNS zone** — an `A` record to the private IP. Resolves
  anywhere but only connects from inside the network; it publishes an internal
  address, which some organizations disallow.

### TLS

In self-signed mode (the default), `tls.tf` creates a small **per-deployment
CA** and signs the serving certificate with it. In internal mode that CA is
uploaded to the Terraform-managed gateway as the trusted root `fortiaigate-ca`,
and the Ingress gets
`appgw.ingress.kubernetes.io/appgw-trusted-root-certificate: fortiaigate-ca`, so
the gateway trusts the HTTPS backends. This removes the self-signed **502**.

- **Browser warning.** Browsers still don't know the CA. Export it with
  `terraform output -raw tls_ca_certificate > fortiaigate-ca.pem` and import it
  into client trust stores (or push it by policy). A new CA is generated on
  every rebuild, so re-distribute after a teardown.
- **Certificate names.** The serving cert covers `ingress_host`, `localhost`
  (AGIC's default probe host) and the in-cluster Service names.
- **Database TLS is unchanged.** `tls.crt` carries the full chain (leaf + CA),
  and the chart uses that file as the CA bundle for PostgreSQL/Redis clients.
  Verified with psql `verify-full`, `redis-cli --tls`, and Python `ssl` with
  hostname checking.
- **Let's Encrypt** (`letsencrypt_enabled = true`) remains the option for a
  browser-trusted cert without distributing a CA. It needs the domain in a
  **public Azure DNS zone**: DNS-01 only writes `_acme-challenge` TXT records
  there, and the UI's `A` record can live in internal DNS. If you also create an
  Azure **Private** DNS zone with the same name linked to this VNet,
  cert-manager's propagation self-check resolves the private zone and never sees
  the TXT record, so run cert-manager with
  `--dns01-recursive-nameservers-only --dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53`.
- **Public mode** uses the add-on's gateway, which Terraform doesn't manage, so
  the CA is **not** uploaded there and self-signed public mode still returns
  502. Use Let's Encrypt for a public UI.
- **No usable DNS yet.** `node scripts/ui-proxy.mjs` from a machine with
  cluster access reaches the UI through port-forwards, bypassing the gateway.

### Switching an existing cluster

Flipping `internal` on a live cluster re-points the add-on at a different
gateway: `false → true` creates the Terraform gateway and leaves the add-on's
old public gateway orphaned in the `MC_...` group (delete it manually, or it
goes with the cluster at teardown); `true → false` makes the add-on create a new
public gateway and Terraform destroys its own. The ingress address changes
either way. Prefer choosing the mode at deploy time.

### Locking down the public IP

In internal mode the public IP has no listener, so nothing is served on it. If
policy requires it, attach an NSG to the appgw subnet that denies Internet
inbound — but it **must** still allow `GatewayManager` inbound on
`65200-65535` and `AzureLoadBalancer` inbound, or the gateway goes unhealthy.

## AGIC permissions

AGIC uses an addon-managed identity to create and update Application Gateway.
When the gateway joins the `appgw` subnet in this stack's VNet, that identity
needs subnet permissions including:

- `Microsoft.Network/virtualNetworks/subnets/read`
- `Microsoft.Network/virtualNetworks/subnets/join/action`

The stack codifies this with:

```hcl
azurerm_role_assignment.agic_appgw_subnet_network_contributor
```

Without that grant, AGIC logs show
`ApplicationGatewayInsufficientPermissionOnSubnet` and the ingress never gets
an address.

In internal mode the gateway is Terraform-managed, and AKS does not grant the
add-on identity rights on a gateway it didn't create. The stack adds:

```hcl
azurerm_role_assignment.agic_appgw_contributor   # Contributor on the gateway
azurerm_role_assignment.agic_rg_reader           # Reader on the cluster resource group
```

Without them AGIC logs authorization failures and never programs listeners.
