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
    [for f in sort(fileset("${path.module}/fortiaigate", "charts/**")) : filesha256("${path.module}/fortiaigate/${f}")],
  )))

  license_cm_name = length(kubernetes_config_map.licenses) > 0 ? "fortiaigate-license-config" : ""
  license_checksum = length(var.licenses) > 0 ? sha256(jsonencode({
    for node_name, license_path in var.licenses : node_name => filesha256(license_path)
  })) : ""

  # Pass node names into global.licenses so the Helm affinity blocks can use them.
  # Values are empty strings — the actual license content lives in the ConfigMap created
  # by licenses.tf. Node names contain dots so set{} blocks can't be used here.
  license_node_values = length(var.licenses) > 0 ? [yamlencode({
    global = {
      licenses = { for node_name, _ in var.licenses : node_name => "" }
    }
  })] : []

  # GPU placement values — only included when gpu_enabled = true.
  # Using yamlencode avoids the set{} block limitation with YAML lists (tolerations).
  gpu_values = var.gpu_enabled ? [yamlencode({
    fortiaigate = {
      gpuWorkloadPlacement = {
        nodeSelector = { fortiaigate-role = "gpu" }
        tolerations = [{
          key      = "fortiaigate-gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }]
      }
    }
    license_manager = {
      placement = {
        tolerations = [{
          key      = "fortiaigate-gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }]
      }
    }
  })] : []

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
  # chart's default name, so api/core/logd (which reference
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

  # Internal mode + self-signed TLS: tell AGIC to validate the HTTPS backends
  # against the per-deployment CA that appgw.tf uploads as a trusted root.
  # Without it the gateway can't trust the backend cert and returns 502. Public
  # mode's add-on gateway isn't Terraform-managed, so the CA isn't uploaded there;
  # Let's Encrypt chains to a well-known CA and needs nothing.
  appgw_trusted_root_values = (local.appgw_byo && !var.letsencrypt_enabled) ? [yamlencode({
    ingress = {
      annotations = {
        "appgw.ingress.kubernetes.io/appgw-trusted-root-certificate" = local.appgw_trusted_root_name
      }
    }
  })] : []

  # The chart mounts fortiaigate-tls-secret by name (tls.existingSecret). Who
  # owns it depends on the mode:
  #   - self-signed (default): Terraform's kubernetes_secret.tls owns it, and the
  #     checksum is the cert content so regenerating it triggers a pod rollout.
  #   - Let's Encrypt: cert-manager owns it (certmanager.tf). Terraform doesn't
  #     know the cert content, so the checksum keys off the ACME environment
  #     instead -- flipping staging->production rolls the pods to pick up the new
  #     cert. The name is the well-known secret cert-manager writes to.
  tls_secret_name     = var.letsencrypt_enabled ? "fortiaigate-tls-secret" : kubernetes_secret.tls[0].metadata[0].name
  tls_secret_checksum = var.letsencrypt_enabled ? "letsencrypt-${var.letsencrypt_environment}" : sha256(tls_locally_signed_cert.fortiaigate[0].cert_pem)
  tls_values = [yamlencode({
    tls = {
      enabled                = true
      existingSecret         = local.tls_secret_name
      existingSecretChecksum = local.tls_secret_checksum
      # In Let's Encrypt mode cert-manager rewrites the secret out-of-band from
      # any terraform apply (90-day renewals) and finishes the staging->prod
      # issuance minutes AFTER the checksum-triggered roll fires, so the pods can
      # come up on the old/staging cert. The Reloader controller (installed below,
      # also LE-only) watches the secret and rolls core/api/webui when it actually
      # changes, which closes that race and handles silent renewals. Off for
      # self-signed mode, where the cert exists at apply time and the checksum roll
      # is sufficient.
      reloaderEnabled = var.letsencrypt_enabled
    }
    postgresql = {
      tls = {
        certificatesSecret = local.tls_secret_name
      }
      primary = {
        podAnnotations = {
          "checksum/tls" = local.tls_secret_checksum
        }
      }
    }
    redis = {
      tls = {
        existingSecret = local.tls_secret_name
      }
      master = {
        podAnnotations = {
          "checksum/tls" = local.tls_secret_checksum
        }
      }
    }
  })]

  # In Let's Encrypt mode the bundled PostgreSQL and Redis CANNOT use the shared
  # secret. The chart points every app pod's REDIS_SSL_CA_CERTS /
  # POSTGRES_SSL_CA_CERTS -- and redis's own probe (certCAFilename: tls.crt) --
  # at the serving cert AS its own CA, which is only valid for a self-signed
  # cert. An ACME leaf can't validate itself, so redis crashloops on
  # "tlsv1 alert unknown ca" and app->DB TLS breaks. Disable DB TLS in LE mode
  # so the LE cert is used only for the app serving cert + ingress listener
  # (which is what fixes the backend 502 and the browser warning). Self-signed
  # mode keeps DB TLS on, unchanged. The proper alternative -- keep DB TLS via a
  # separate self-signed secret -- needs a chart change mirrored to the EKS repo
  # (see docs/tls-letsencrypt.md). This leaves database traffic unencrypted,
  # potentially across nodes when multiple app nodes are licensed; see ROADMAP.md.
  # Appended AFTER tls_values so enabled=false wins.
  db_tls_values = var.letsencrypt_enabled ? [yamlencode({
    postgresql = { tls = { enabled = false } }
    redis      = { tls = { enabled = false } }
  })] : []
}

# PostgreSQL credentials, owned by Terraform rather than the Helm release.
#
# PostgreSQL stores the role passwords inside its data directory at initdb and
# never re-reads them from the Secret. The data lives on a StatefulSet PVC that
# survives `helm uninstall`, but a chart-generated Secret does not — so any
# uninstall/reinstall (e.g. clearing a stuck pending-install) used to mint a new
# random password that no longer matched the retained database, and api/core/logd
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
# and rolls the core/api/webui Deployments (annotated by the chart when
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
  version   = "8.0.1"
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
    precondition {
      condition = !var.gpu_enabled || length([
        for node_name in keys(var.licenses) : node_name
        if can(regex("^aks-gpu-", node_name))
      ]) > 0
      error_message = "gpu_enabled=true requires var.licenses to include the GPU AKS node name, usually aks-gpu-... Run the targeted infrastructure apply first, then run `kubectl get nodes -o custom-columns=NAME:.metadata.name,ROLE:.metadata.labels.fortiaigate-role --no-headers` and add both app and gpu node licenses before the full apply."
    }
  }

  depends_on = [
    kubernetes_storage_class.azurefile,
    kubernetes_config_map.licenses,
    kubernetes_secret.tls,
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
    local.gpu_values,
    local.db_storage_values,
    local.db_auth_values,
    local.internal_appgw_values,
    local.appgw_trusted_root_values,
    local.ingress_annotation_values,
    local.tls_values,
    local.db_tls_values,
    local.license_node_values,
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
  set {
    name  = "license.existingConfigMap"
    value = local.license_cm_name
  }
  # Roll license-manager when a license file's CONTENT changes (e.g. swapping a
  # license that is "In Use" elsewhere for a free one under the same node name).
  # Only the ConfigMap changes in that case, which Kubernetes does not propagate
  # to running pods on its own.
  set {
    name  = "license.checksum"
    value = local.license_checksum
  }
}
