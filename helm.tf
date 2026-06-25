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
  license_cm_name = length(kubernetes_config_map.licenses) > 0 ? "fortiaigate-license-config" : ""

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
  # correct backing. Done here rather than in values.yaml so the chart stays
  # identical to the EKS stack (which sets its own gp3/EBS class the same way).
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

  # Ingress annotations — yamlencode handles keys with dots and slashes correctly,
  # which the set{} name path syntax cannot express.
  ingress_annotation_values = length(var.ingress_annotations) > 0 ? [yamlencode({
    ingress = { annotations = var.ingress_annotations }
  })] : []

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

  # The chart mounts fortiaigate-tls-secret by name (tls.existingSecret). Who
  # owns it depends on the mode:
  #   - self-signed (default): Terraform's kubernetes_secret.tls owns it, and the
  #     checksum is the cert content so regenerating it triggers a pod rollout.
  #   - Let's Encrypt: cert-manager owns it (certmanager.tf). Terraform doesn't
  #     know the cert content, so the checksum keys off the ACME environment
  #     instead -- flipping staging->production rolls the pods to pick up the new
  #     cert. The name is the well-known secret cert-manager writes to.
  tls_secret_name     = var.letsencrypt_enabled ? "fortiaigate-tls-secret" : kubernetes_secret.tls[0].metadata[0].name
  tls_secret_checksum = var.letsencrypt_enabled ? "letsencrypt-${var.letsencrypt_environment}" : sha256(tls_self_signed_cert.fortiaigate[0].cert_pem)
  tls_values = [yamlencode({
    tls = {
      existingSecret         = local.tls_secret_name
      existingSecretChecksum = local.tls_secret_checksum
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

resource "helm_release" "fortiaigate" {
  name      = "fortiaigate"
  chart     = "${path.module}/fortiaigate"
  namespace = kubernetes_namespace.fortiaigate.metadata[0].name
  timeout   = var.helm_timeout

  lifecycle {
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
    # In Let's Encrypt mode this owns fortiaigate-tls-secret instead; both are
    # counted resources, so whichever is inactive is simply an empty dependency.
    helm_release.cert_manager_issuer,
    helm_release.nvidia_device_plugin,
  ]

  # Values are merged left-to-right; later entries take precedence.
  # User-supplied extra_values_files go first so gpu and annotation overrides win.
  values = concat(
    [for f in var.extra_values_files : file(f)],
    local.gpu_values,
    local.db_storage_values,
    local.internal_appgw_values,
    local.ingress_annotation_values,
    local.tls_values,
    local.license_node_values,
  )

  set {
    name  = "fortiaigate.image.repository"
    value = var.image_repository
  }
  set {
    name  = "fortiaigate.image.tag"
    value = var.image_tag
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
}
