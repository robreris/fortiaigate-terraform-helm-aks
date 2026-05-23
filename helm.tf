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

  # Terraform owns the TLS Secret, so pass both the name and a stable checksum
  # into Helm. Pod template annotations use the checksum to trigger rollouts
  # when Terraform regenerates the certificate.
  tls_secret_name     = kubernetes_secret.tls.metadata[0].name
  tls_secret_checksum = sha256(tls_self_signed_cert.fortiaigate.cert_pem)
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
  timeout   = 1200

  depends_on = [
    kubernetes_storage_class.azurefile,
    kubernetes_config_map.licenses,
    kubernetes_secret.tls,
    helm_release.nvidia_device_plugin,
  ]

  # Values are merged left-to-right; later entries take precedence.
  # User-supplied extra_values_files go first so gpu and annotation overrides win.
  values = concat(
    [for f in var.extra_values_files : file(f)],
    local.gpu_values,
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
