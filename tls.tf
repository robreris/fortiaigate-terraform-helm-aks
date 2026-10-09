# Keep generated TLS material for internal services and databases in every mode.
# Existing generated resource addresses are retained for upgrade compatibility.
# Web/API HTTPS uses generated material, supplied PEM files, or cert-manager.
# No CA private key is needed when supplying a serving certificate.

locals {
  supplied_tls         = var.tls_certificate_path != ""
  generated_web_tls    = !var.letsencrypt_enabled && !local.supplied_tls
  supplied_certificate = local.supplied_tls ? try(file(var.tls_certificate_path), "") : ""
  supplied_private_key = var.tls_private_key_path != "" ? sensitive(try(file(var.tls_private_key_path), "")) : ""
  web_trusted_root     = local.generated_web_tls ? tls_self_signed_cert.ca[0].cert_pem : (var.tls_ca_certificate_path != "" ? try(file(var.tls_ca_certificate_path), "") : "")
  web_has_private_ca   = local.generated_web_tls || var.tls_ca_certificate_path != ""
  tls_common_name      = var.ingress_host != "" ? var.ingress_host : "fortiaigate.local"
}

resource "tls_private_key" "ca" {
  count     = 1
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "ca" {
  count           = 1
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
  count     = 1
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "fortiaigate" {
  count           = 1
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
      for svc in ["llm-gateway", "api", "webui", "license-manager", "fortiaigate-postgresql", "fortiaigate-redis-master", "guardrail", "dlp-scanner", "policy-guard", "dp-agent", "logd"] : [
        svc,
        "${svc}.${var.namespace}",
        "${svc}.${var.namespace}.svc",
        "${svc}.${var.namespace}.svc.cluster.local",
      ]
    ]),
  )))
}

resource "tls_locally_signed_cert" "fortiaigate" {
  count              = 1
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
  depends_on = [terraform_data.tls_configuration]
  count      = var.letsencrypt_enabled ? 0 : 1

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
    "tls.crt" = local.supplied_tls ? local.supplied_certificate : "${tls_locally_signed_cert.fortiaigate[0].cert_pem}${tls_self_signed_cert.ca[0].cert_pem}"
    "tls.key" = local.supplied_tls ? local.supplied_private_key : tls_private_key.fortiaigate[0].private_key_pem
    "ca.crt"  = local.web_trusted_root
  }
}

# Configuration checks also run when cert-manager owns the web secret.
resource "terraform_data" "tls_configuration" {
  input = local.supplied_tls ? "supplied" : (var.letsencrypt_enabled ? "letsencrypt" : "generated")

  lifecycle {
    precondition {
      condition     = (var.tls_certificate_path != "") == (var.tls_private_key_path != "")
      error_message = "Set both tls_certificate_path and tls_private_key_path, or leave both empty."
    }
    precondition {
      condition     = !local.supplied_tls || (!var.letsencrypt_enabled && trimspace(var.ingress_host) != "")
      error_message = "Supplied TLS requires ingress_host and letsencrypt_enabled=false."
    }
    precondition {
      condition     = var.tls_ca_certificate_path == "" || local.supplied_tls
      error_message = "tls_ca_certificate_path is only valid with a supplied serving certificate."
    }
  }
}

resource "kubernetes_secret" "internal_tls" {
  metadata {
    name      = "fortiaigate-internal-tls-secret"
    namespace = kubernetes_namespace.fortiaigate.metadata[0].name
  }
  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = "${tls_locally_signed_cert.fortiaigate[0].cert_pem}${tls_self_signed_cert.ca[0].cert_pem}"
    "tls.key" = tls_private_key.fortiaigate[0].private_key_pem
    "ca.crt"  = tls_self_signed_cert.ca[0].cert_pem
  }
}
