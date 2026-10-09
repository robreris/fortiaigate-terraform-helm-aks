resource "kubernetes_namespace" "fortiaigate" {
  metadata {
    name = var.namespace
  }

  timeouts {
    delete = "1h"
  }

  depends_on = [azurerm_kubernetes_cluster.this]
}

locals {
  # The Helm provider sees a constant local chart path. Include a digest in
  # values so edits to the local chart trigger an in-place release upgrade.
  chart_revision = sha256(join("", concat(
    [filesha256("${path.module}/fortiaigate/Chart.yaml"), filesha256("${path.module}/fortiaigate/values.yaml")],
    [for f in sort(fileset("${path.module}/fortiaigate", "templates/**")) : filesha256("${path.module}/fortiaigate/${f}")],
    [for f in sort(fileset("${path.module}/fortiaigate", "files/**")) : filesha256("${path.module}/fortiaigate/${f}")],
    [for f in sort(fileset("${path.module}/fortiaigate", "charts/**")) : filesha256("${path.module}/fortiaigate/${f}")],
  )))

  # Placement is independent of deployment licensing. GPU nodes are tainted.
  placement_values = [yamlencode({
    fortiaigate = {
      appWorkloadPlacement = { nodeSelector = { fortiaigate-role = "app" } }
      gpuWorkloadPlacement = {
        nodeSelector = { fortiaigate-role = "gpu" }
        tolerations = [{
          key = "fortiaigate-gpu", operator = "Equal", value = "true", effect = "NoSchedule"
        }]
      }
    }
    postgresql = { primary = { nodeSelector = { fortiaigate-role = "app" } } }
    redis      = { master = { nodeSelector = { fortiaigate-role = "app" } } }
  })]

  # Terraform-owned secrets survive Helm reinstall with retained database data.
  application_secret_values = [yamlencode({
    api         = { masterKeyExistingSecret = kubernetes_secret.application.metadata[0].name }
    dpAgent     = { masterKeyExistingSecret = kubernetes_secret.application.metadata[0].name }
    fortiaigate = { env = { csrfExistingSecret = kubernetes_secret.application.metadata[0].name } }
    redis       = { auth = { existingSecret = kubernetes_secret.redis.metadata[0].name } }
  })]

  # Move PostgreSQL and Redis off the shared Azure Files (SMB) claim onto their
  # own dynamically-provisioned Azure Disk PVCs. The chart's values default both
  # subcharts to existingClaim "fortiaigate-storage" (the RWX SMB share), but
  # PostgreSQL's initdb fails on SMB — it requires a data dir owned by the db
  # user at 0700 with POSIX fsync/locking, which CIFS/SMB does not provide, so
  # the pod crashloops with exit 1 right before initdb runs. Two stateful
  # services sharing one RWX volume is also wrong. Block storage (RWO) is the
  # correct backing. Keep this platform-specific override in Terraform rather
  # than changing the upstream chart's default shared-PVC values.
  db_storage_values = [yamlencode({
    postgresql = {
      primary = {
        persistence = {
          existingClaim = ""
          storageClass  = var.db_storage_class
          accessModes   = ["ReadWriteOnce"]
        }
      }
    }
    redis = {
      master = {
        persistence = {
          existingClaim = ""
          storageClass  = var.db_storage_class
          accessModes   = ["ReadWriteOnce"]
        }
      }
    }
  })]

  # Point the bundled PostgreSQL at the Terraform-owned credential Secret below
  # instead of letting Bitnami generate a random one. The Secret keeps the
  # chart's default name, so api/llm-gateway/logd (which reference
  # <release>-postgresql / key "password") need no template changes.
  db_auth_values = [yamlencode({
    postgresql = {
      auth = {
        existingSecret = kubernetes_secret.postgresql.metadata[0].name
      }
    }
  })]

  # Ingress annotations — yamlencode handles keys with dots and slashes correctly,
  # which the set{} name path syntax cannot express.
  ingress_annotation_values = [yamlencode({
    ingress = {
      annotations = merge(
        var.ingress_class == "azure-application-gateway" ? {
          "appgw.ingress.kubernetes.io/backend-protocol" = "https"
          "appgw.ingress.kubernetes.io/ssl-redirect"     = "true"
        } : {},
        var.ingress_class == "azure-application-gateway" && !local.generated_web_tls ? {
          "appgw.ingress.kubernetes.io/backend-hostname"      = var.ingress_host
          "appgw.ingress.kubernetes.io/health-probe-hostname" = var.ingress_host
        } : {},
        var.ingress_annotations,
      )
    }
  })]

  # Internal Application Gateway: AGIC reads this annotation to tell the
  # gateway to use a private frontend IP only. Placed before
  # ingress_annotation_values so explicit user annotations can still override.
  internal_appgw_values = (var.internal && var.ingress_class == "azure-application-gateway") ? [yamlencode({
    ingress = {
      annotations = {
        "appgw.ingress.kubernetes.io/use-private-ip" = "true"
      }
    }
  })] : []

  # Private gateways trust the generated or supplied web CA uploaded in appgw.tf.
  # Public add-on gateways require manual private-root installation; publicly
  # trusted web certificates need no custom root upload.
  appgw_trusted_root_values = (local.appgw_byo && local.web_has_private_ca) ? [yamlencode({
    ingress = {
      annotations = {
        "appgw.ingress.kubernetes.io/appgw-trusted-root-certificate" = local.appgw_trusted_root_name
      }
    }
  })] : []

  # Web/API and internal services have independent secrets and rollout checksums.
  tls_secret_name       = var.letsencrypt_enabled ? "fortiaigate-tls-secret" : kubernetes_secret.tls[0].metadata[0].name
  tls_secret_checksum   = var.letsencrypt_enabled ? "letsencrypt-${var.letsencrypt_environment}" : sha256(local.supplied_tls ? local.supplied_certificate : tls_locally_signed_cert.fortiaigate[0].cert_pem)
  internal_tls_checksum = sha256(tls_locally_signed_cert.fortiaigate[0].cert_pem)
  tls_values = [yamlencode({
    tls = {
      enabled                        = true
      existingSecret                 = local.tls_secret_name
      existingSecretChecksum         = local.tls_secret_checksum
      internalExistingSecret         = kubernetes_secret.internal_tls.metadata[0].name
      internalExistingSecretChecksum = local.internal_tls_checksum
      internalMountPath              = "/etc/internal-tls"
      reloaderEnabled                = var.letsencrypt_enabled
    }
    postgresql = {
      tls = {
        enabled            = true
        certificatesSecret = kubernetes_secret.internal_tls.metadata[0].name
      }
      primary = {
        podAnnotations = { "checksum/tls" = local.internal_tls_checksum }
      }
    }
    redis = {
      tls = {
        enabled        = true
        existingSecret = kubernetes_secret.internal_tls.metadata[0].name
        certCAFilename = "ca.crt"
      }
      master = {
        podAnnotations = { "checksum/tls" = local.internal_tls_checksum }
      }
    }
  })]
}

# PostgreSQL credentials, owned by Terraform rather than the Helm release.
#
# PostgreSQL stores the role passwords inside its data directory at initdb and
# never re-reads them from the Secret. The data lives on a StatefulSet PVC that
# survives `helm uninstall`, but a chart-generated Secret does not — so any
# uninstall/reinstall (e.g. clearing a stuck pending-install) used to mint a new
# random password that no longer matched the retained database, and api/llm-gateway/logd
# crashlooped on "password authentication failed". Owning the Secret here ties
# the password's lifetime to Terraform state instead of the Helm release.
#
# ignore_changes = all: a password is only ever set at initdb, so a regenerated
# value would silently break an existing database. Never let a config tweak (or
# the attribute defaults set by `terraform import`) replace these. Rotating the
# password requires ALTER ROLE inside PostgreSQL as well — see docs.
resource "random_password" "postgresql_user" {
  length  = 32
  special = false

  lifecycle {
    ignore_changes = all
  }
}

resource "random_password" "postgresql_admin" {
  length  = 32
  special = false

  lifecycle {
    ignore_changes = all
  }
}

resource "kubernetes_secret" "postgresql" {
  metadata {
    name      = "fortiaigate-postgresql"
    namespace = kubernetes_namespace.fortiaigate.metadata[0].name

    annotations = {
      # Deployments created before this Secret moved to Terraform have it in the
      # Helm release manifest. On the upgrade that sets existingSecret, Helm
      # deletes resources that left the manifest unless the LIVE object carries
      # this policy — so it must stay set (Terraform applies it before the
      # helm_release upgrade, which references this resource).
      "helm.sh/resource-policy" = "keep"
    }
  }

  type = "Opaque"

  # Key names are the Bitnami chart defaults (auth.secretKeys.userPasswordKey /
  # adminPasswordKey) and what the fortiaigate templates read.
  data = {
    "password"          = random_password.postgresql_user.result
    "postgres-password" = random_password.postgresql_admin.result
  }
}

resource "helm_release" "nvidia_device_plugin" {
  count = var.gpu_enabled ? 1 : 0

  name       = "nvidia-device-plugin"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  version    = "0.14.5"
  namespace  = "kube-system"

  set {
    name  = "nodeSelector.fortiaigate-role"
    value = "gpu"
  }
  set {
    name  = "tolerations[0].key"
    value = "fortiaigate-gpu"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "tolerations[0].value"
    value = "true"
    type  = "string"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }

  depends_on = [azurerm_kubernetes_cluster_node_pool.gpu]
}

# Stakater Reloader — only in Let's Encrypt mode. It watches fortiaigate-tls-secret
# and rolls the llm-gateway/api/webui Deployments (annotated by the chart when
# tls.reloaderEnabled) whenever cert-manager rewrites the cert: the staging->prod
# flip and silent 90-day renewals both land in the secret out-of-band from any
# terraform apply, so the checksum-based roll alone can serve a stale cert (the
# 502 we hit on bring-up). watchGlobally=false + a fortiaigate-namespace install
# scopes the controller to just this namespace. Self-signed mode doesn't install
# it (the cert is apply-time, no race).
resource "helm_release" "reloader" {
  count = var.letsencrypt_enabled ? 1 : 0

  name       = "reloader"
  repository = "https://stakater.github.io/stakater-charts"
  chart      = "reloader"
  version    = "2.2.12"
  namespace  = kubernetes_namespace.fortiaigate.metadata[0].name

  set {
    name  = "reloader.watchGlobally"
    value = "false"
  }

  depends_on = [kubernetes_namespace.fortiaigate]
}

resource "helm_release" "fortiaigate" {
  name      = "fortiaigate"
  chart     = "${path.module}/fortiaigate"
  version   = "8.0.2"
  namespace = kubernetes_namespace.fortiaigate.metadata[0].name
  timeout   = var.helm_timeout

  lifecycle {
    precondition {
      condition     = var.agic_enabled || var.ingress_class != "azure-application-gateway"
      error_message = "ingress_class is azure-application-gateway, but agic_enabled is false. Select an installed ingress controller or enable AGIC."
    }
    precondition {
      condition     = !var.internal || (var.agic_enabled && var.ingress_class == "azure-application-gateway")
      error_message = "internal = true is implemented through AGIC's private frontend (appgw.tf) and requires agic_enabled = true with ingress_class = \"azure-application-gateway\". For another controller, configure its internal load balancer directly."
    }
  }

  depends_on = [
    kubernetes_storage_class.azurefile,
    kubernetes_secret.application,
    kubernetes_secret.redis,
    kubernetes_secret.tls,
    kubernetes_secret.internal_tls,
    terraform_data.tls_configuration,
    # The trusted root must exist on the gateway before AGIC reads the annotation.
    azurerm_application_gateway.this,
    # In Let's Encrypt mode this owns fortiaigate-tls-secret instead; both are
    # counted resources, so whichever is inactive is simply an empty dependency.
    helm_release.cert_manager_issuer,
    helm_release.nvidia_device_plugin,
    # Bring the Reloader controller up before the app so it's already watching
    # the secret when cert-manager issues the first production cert. Zero
    # resources (and an empty dependency) when letsencrypt_enabled = false.
    helm_release.reloader,
    azurerm_role_assignment.kubelet_acr_pull,
    azurerm_role_assignment.agic_appgw_subnet_network_contributor,
    # Internal mode only (zero resources otherwise): AGIC's rights on the
    # Terraform-managed gateway.
    azurerm_role_assignment.agic_appgw_contributor,
    azurerm_role_assignment.agic_rg_reader,
  ]

  # Values are merged left-to-right; later entries take precedence. Terraform's
  # managed GPU, storage, ingress, TLS and license settings override extras.
  # The set blocks below have final precedence for directly mapped variables.
  values = concat(
    [for f in var.extra_values_files : file(f)],
    local.placement_values,
    local.application_secret_values,
    local.db_storage_values,
    local.db_auth_values,
    local.internal_appgw_values,
    local.appgw_trusted_root_values,
    local.ingress_annotation_values,
    local.tls_values,
  )

  set {
    name  = "deployment.chartRevision"
    value = local.chart_revision
  }
  set {
    name  = "fortiaigate.image.repository"
    value = var.image_repository
  }
  set {
    name  = "fortiaigate.image.tag"
    value = var.image_tag
  }
  set {
    name  = "triton.image.serverTag"
    value = var.triton_image_tag
  }
  set {
    name  = "triton.image.modelsTag"
    value = var.triton_models_image_tag
  }
  set {
    name  = "vllm.image.tag"
    value = var.vllm_image_tag
  }
  set {
    name  = "vllm.gpuAttach"
    value = var.vllm_gpu_attach
  }
  # The supplied bundle has no dp_agent image. Keep it disabled in this port.
  set {
    name  = "dpAgent.enabled"
    value = "false"
  }
  set {
    name  = "fortiaigate.gpu.enabled"
    value = tostring(var.gpu_enabled)
  }
  set {
    name  = "fortiaigate.updateStrategy"
    value = var.update_strategy
  }
  set {
    name  = "ingress.className"
    value = var.ingress_class
  }
  set {
    name  = "ingress.host"
    value = var.ingress_host
  }
  set {
    name  = "storage.storageClass"
    value = "azurefile-fortiaigate"
  }
  set {
    name  = "storage.size"
    value = var.storage_size
  }
}
