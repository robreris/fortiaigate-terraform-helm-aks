# Generate a self-signed TLS certificate at apply time so no private key material
# needs to live in the repository.
#
# This is the default (var.letsencrypt_enabled = false). When Let's Encrypt is
# enabled, cert-manager owns fortiaigate-tls-secret instead (see certmanager.tf),
# so all three resources here resolve to zero and Terraform stops managing the
# secret -- letting cert-manager's Certificate create and rotate it.

resource "tls_private_key" "fortiaigate" {
  count     = var.letsencrypt_enabled ? 0 : 1
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "fortiaigate" {
  count           = var.letsencrypt_enabled ? 0 : 1
  private_key_pem = tls_private_key.fortiaigate[0].private_key_pem

  subject {
    common_name  = var.ingress_host != "" ? var.ingress_host : "fortiaigate.local"
    organization = "FortiAIGate"
  }

  validity_period_hours = 8760 # 1 year

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "kubernetes_secret" "tls" {
  count = var.letsencrypt_enabled ? 0 : 1

  metadata {
    name      = "fortiaigate-tls-secret"
    namespace = kubernetes_namespace.fortiaigate.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "Helm"
    }

    annotations = {
      "meta.helm.sh/release-name"      = "fortiaigate"
      "meta.helm.sh/release-namespace" = kubernetes_namespace.fortiaigate.metadata[0].name
    }
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = tls_self_signed_cert.fortiaigate[0].cert_pem
    "tls.key" = tls_private_key.fortiaigate[0].private_key_pem
  }
}
