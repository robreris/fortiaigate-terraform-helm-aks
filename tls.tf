# Generate the TLS material at apply time so no private key material needs to
# live in the repository.
#
# This is the default (var.letsencrypt_enabled = false). When Let's Encrypt is
# enabled, cert-manager owns fortiaigate-tls-secret instead (see certmanager.tf),
# so every resource here resolves to zero and Terraform stops managing the
# secret -- letting cert-manager's Certificate create and rotate it.
#
# Why a private CA rather than a bare self-signed cert: Application Gateway v2
# only trusts an HTTPS backend whose chain ends in a well-known CA or in a
# ROOT certificate uploaded to the gateway (a CA cert, not a self-signed leaf).
# A bare self-signed serving cert therefore made every AGIC backend unhealthy
# (the 502). The serving cert is now signed by a per-deployment CA; in internal
# mode appgw.tf uploads that CA as the gateway's trusted root and helm.tf points
# the Ingress at it. In public mode the add-on owns the gateway, so the CA is
# not uploaded automatically (see docs/application-gateway-dns-tls.md).
#
# The chart uses tls.crt as the CA bundle for Redis/PostgreSQL client
# verification (REDIS_SSL_CA_CERTS / POSTGRES_SSL_CA_CERTS / certCAFilename),
# so tls.crt carries the full chain (leaf + CA): servers present the chain and
# clients find the CA in the same file.

locals {
  tls_common_name = var.ingress_host != "" ? var.ingress_host : "fortiaigate.local"
}

resource "tls_private_key" "ca" {
  count     = var.letsencrypt_enabled ? 0 : 1
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "ca" {
  count           = var.letsencrypt_enabled ? 0 : 1
  private_key_pem = tls_private_key.ca[0].private_key_pem

  is_ca_certificate = true

  subject {
    common_name  = "FortiAIGate ${var.cluster_name} CA"
    organization = "FortiAIGate"
  }

  validity_period_hours = 43800 # 5 years

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
  ]
}

resource "tls_private_key" "fortiaigate" {
  count     = var.letsencrypt_enabled ? 0 : 1
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "fortiaigate" {
  count           = var.letsencrypt_enabled ? 0 : 1
  private_key_pem = tls_private_key.fortiaigate[0].private_key_pem

  subject {
    common_name  = local.tls_common_name
    organization = "FortiAIGate"
  }

  # The gateway matches the backend cert against the request host (ingress_host)
  # and, for AGIC's derived probes with no host, "localhost". The in-cluster
  # Service names cover the chart's pod-to-pod and database TLS connections.
  dns_names = distinct(compact(concat(
    [var.ingress_host, "localhost"],
    flatten([
      for svc in ["core", "api", "webui", "license-manager", "fortiaigate-postgresql", "fortiaigate-redis-master"] : [
        svc,
        "${svc}.${var.namespace}",
        "${svc}.${var.namespace}.svc",
        "${svc}.${var.namespace}.svc.cluster.local",
      ]
    ]),
  )))
}

resource "tls_locally_signed_cert" "fortiaigate" {
  count              = var.letsencrypt_enabled ? 0 : 1
  cert_request_pem   = tls_cert_request.fortiaigate[0].cert_request_pem
  ca_private_key_pem = tls_private_key.ca[0].private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca[0].cert_pem

  validity_period_hours = 8760 # 1 year

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
    "client_auth",
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
    # Full chain: leaf first, then the CA (see the header comment).
    "tls.crt" = "${tls_locally_signed_cert.fortiaigate[0].cert_pem}${tls_self_signed_cert.ca[0].cert_pem}"
    "tls.key" = tls_private_key.fortiaigate[0].private_key_pem
    "ca.crt"  = tls_self_signed_cert.ca[0].cert_pem
  }
}
