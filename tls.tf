# Generate a self-signed TLS certificate at apply time so no private key material
# needs to live in the repository. Replace this with a Key Vault-issued or
# cert-manager-managed cert for production use.

resource "tls_private_key" "fortiaigate" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "fortiaigate" {
  private_key_pem = tls_private_key.fortiaigate.private_key_pem

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
    "tls.crt" = tls_self_signed_cert.fortiaigate.cert_pem
    "tls.key" = tls_private_key.fortiaigate.private_key_pem
  }
}
