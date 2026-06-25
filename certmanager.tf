# Automated Let's Encrypt TLS via cert-manager + Azure DNS (DNS-01),
# authenticated through workload identity (no service-principal secret).
#
# This whole file is gated on var.letsencrypt_enabled. When false it resolves
# to zero resources and tls.tf's self-signed certificate is used instead, so
# the default behaviour is unchanged.
#
# When true:
#   - cert-manager is installed and its controller assumes a user-assigned
#     identity via a federated credential bound to the cluster OIDC issuer.
#   - That identity holds DNS Zone Contributor on the (externally-created)
#     Azure DNS zone, so cert-manager can write the _acme-challenge TXT records.
#   - A small local chart (certmanager-issuer/) deploys the ClusterIssuer and a
#     Certificate that issues into fortiaigate-tls-secret -- the exact secret the
#     fortiaigate chart already mounts. AGIC also reads that secret (via the
#     ingress spec.tls block) for the frontend listener, so one issued cert
#     covers both the browser-facing listener and the HTTPS backend trust.
#
# This is the first consumer of the cluster's workload identity (oidc_issuer +
# workload_identity, enabled in aks.tf).

data "azurerm_client_config" "current" {}

# The DNS zone is created out-of-band (e.g. App Service Domains). Look it up so
# the cert-manager identity can be scoped to exactly that zone.
data "azurerm_dns_zone" "this" {
  count               = var.letsencrypt_enabled ? 1 : 0
  name                = var.dns_zone_name
  resource_group_name = var.dns_zone_resource_group
}

# User-assigned identity cert-manager federates into. No secret is stored; the
# federated credential below lets the cert-manager ServiceAccount exchange its
# projected OIDC token for an Azure token for this identity.
resource "azurerm_user_assigned_identity" "cert_manager" {
  count               = var.letsencrypt_enabled ? 1 : 0
  name                = "${var.cluster_name}-cert-manager"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}

# DNS Zone Contributor on the zone -- the minimum cert-manager needs to create
# and delete the ACME challenge TXT records. Requires the Terraform principal to
# have role-assignment write (Owner / User Access Administrator) on the zone's
# resource group, same pattern as kubelet_acr_pull in aks.tf.
resource "azurerm_role_assignment" "cert_manager_dns" {
  count                = var.letsencrypt_enabled ? 1 : 0
  scope                = data.azurerm_dns_zone.this[0].id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.cert_manager[0].principal_id
}

# Trust tokens from the cluster OIDC issuer for the cert-manager controller
# ServiceAccount (namespace cert-manager, SA name cert-manager -- the chart
# defaults). The subject MUST match that SA exactly.
resource "azurerm_federated_identity_credential" "cert_manager" {
  count               = var.letsencrypt_enabled ? 1 : 0
  name                = "cert-manager"
  resource_group_name = azurerm_resource_group.this.name
  parent_id           = azurerm_user_assigned_identity.cert_manager[0].id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject             = "system:serviceaccount:cert-manager:cert-manager"
}

# cert-manager. CRDs ship with the chart (crds.enabled -- the v1.15+ key; older
# charts used installCRDs). The controller SA is annotated with the identity
# client ID and the controller pod is labeled so the Azure workload-identity
# webhook projects a federated token into it.
resource "helm_release" "cert_manager" {
  count = var.letsencrypt_enabled ? 1 : 0

  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  namespace        = "cert-manager"
  create_namespace = true

  # yamlencode handles the dotted/slashed label & annotation keys that the
  # set{} name path syntax cannot express.
  values = [yamlencode({
    crds = { enabled = true }
    podLabels = {
      "azure.workload.identity/use" = "true"
    }
    serviceAccount = {
      annotations = {
        "azure.workload.identity/client-id" = azurerm_user_assigned_identity.cert_manager[0].client_id
      }
    }
  })]

  depends_on = [azurerm_kubernetes_cluster.this]
}

# ClusterIssuer + Certificate, shipped as a local chart rather than
# kubernetes_manifest. kubernetes_manifest does a plan-time API dry-run that
# fails because the cert-manager CRDs don't exist until the release above
# installs them in the same apply; Helm has no such plan-time validation.
resource "helm_release" "cert_manager_issuer" {
  count = var.letsencrypt_enabled ? 1 : 0

  name      = "fortiaigate-cert"
  chart     = "${path.module}/certmanager-issuer"
  namespace = kubernetes_namespace.fortiaigate.metadata[0].name

  values = [yamlencode({
    issuerName = "letsencrypt-${var.letsencrypt_environment}"
    acmeServer = var.letsencrypt_environment == "production" ? "https://acme-v02.api.letsencrypt.org/directory" : "https://acme-staging-v02.api.letsencrypt.org/directory"
    email      = var.acme_email
    namespace  = var.namespace
    secretName = "fortiaigate-tls-secret"
    host       = var.ingress_host
    dnsZone = {
      name           = var.dns_zone_name
      resourceGroup  = var.dns_zone_resource_group
      subscriptionID = data.azurerm_client_config.current.subscription_id
    }
    managedIdentityClientID = azurerm_user_assigned_identity.cert_manager[0].client_id
  })]

  lifecycle {
    precondition {
      condition     = var.ingress_host != "" && var.acme_email != "" && var.dns_zone_name != "" && var.dns_zone_resource_group != ""
      error_message = "letsencrypt_enabled = true requires ingress_host, acme_email, dns_zone_name, and dns_zone_resource_group to all be set."
    }
  }

  depends_on = [
    helm_release.cert_manager,
    azurerm_federated_identity_credential.cert_manager,
    azurerm_role_assignment.cert_manager_dns,
    kubernetes_namespace.fortiaigate,
  ]
}
