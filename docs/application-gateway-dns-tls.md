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
pattern is an `A` record to the Application Gateway public IP. If you configure
a DNS label on the public IP, a `CNAME` to that label is also possible.

## TLS options

The stack currently creates `fortiaigate-tls-secret` from a Terraform-generated
self-signed certificate in `tls.tf`. That is useful for bootstrap and encrypted
traffic, but browsers will not trust it for a public UI.

For production, use one of these patterns:

1. Replace the Terraform-generated TLS material with a real certificate for
   `ingress_host` and keep using the Kubernetes TLS secret referenced by the
   Ingress `spec.tls`.
2. Manage the Kubernetes TLS secret with cert-manager. This requires adjusting
   this stack so Terraform does not also own the same `fortiaigate-tls-secret`.
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

`internal = true` adds this AGIC annotation:

```text
appgw.ingress.kubernetes.io/use-private-ip: "true"
```

That tells AGIC to use a private frontend IP. The AKS-managed Application
Gateway created by the add-on must actually have a private frontend for this to
work. If it only has a public frontend, AGIC will not publish an ingress address
for a private ingress.

For private-only deployments, use private DNS that resolves the UI hostname to
the Application Gateway private IP, and verify that the gateway has a private
frontend configuration before relying on `internal = true`.

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
