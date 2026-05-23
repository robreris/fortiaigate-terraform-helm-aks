resource "kubernetes_config_map" "licenses" {
  count = length(var.licenses) > 0 ? 1 : 0

  metadata {
    name      = "fortiaigate-license-config"
    namespace = kubernetes_namespace.fortiaigate.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "Helm"
    }

    annotations = {
      "meta.helm.sh/release-name"      = "fortiaigate"
      "meta.helm.sh/release-namespace" = kubernetes_namespace.fortiaigate.metadata[0].name
    }
  }

  # Read each license file from disk and store its content keyed by node name.
  # The Helm chart's license-manager DaemonSet reads this ConfigMap to obtain
  # the license for whichever node it is running on.
  data = {
    for node_name, license_path in var.licenses : node_name => file(license_path)
  }
}
