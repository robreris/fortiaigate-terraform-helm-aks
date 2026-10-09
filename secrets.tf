# These values must outlive Helm reinstalls against retained database data.
# They are stored in Terraform state; protect state and back them up with data.
resource "random_password" "application_master_key" {
  length  = 32
  special = false

  lifecycle {
    ignore_changes = all
  }
}

resource "random_password" "csrf" {
  length  = 32
  special = false

  lifecycle {
    ignore_changes = all
  }
}

resource "random_password" "redis" {
  length  = 32
  special = false

  lifecycle {
    ignore_changes = all
  }
}

resource "kubernetes_secret" "application" {
  metadata {
    name      = "fortiaigate-application"
    namespace = kubernetes_namespace.fortiaigate.metadata[0].name
  }
  type = "Opaque"
  data = {
    "master-key"      = random_password.application_master_key.result
    "csrf-secret-key" = random_password.csrf.result
  }
}

resource "kubernetes_secret" "redis" {
  metadata {
    name      = "fortiaigate-redis"
    namespace = kubernetes_namespace.fortiaigate.metadata[0].name
    annotations = {
      "helm.sh/resource-policy" = "keep"
    }
  }
  type = "Opaque"
  data = {
    "redis-password" = random_password.redis.result
  }
}
