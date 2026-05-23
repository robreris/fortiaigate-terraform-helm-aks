provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "azuread" {}

# Both the helm and kubernetes providers authenticate via the kubeconfig
# emitted by the AKS resource. On the very first apply (when the cluster
# doesn't exist yet), Terraform defers provider initialization for
# helm/kubernetes until after the AKS module has been applied. If you see
# provider connection errors during 'terraform plan', run:
#   terraform apply -target=azurerm_resource_group.this -target=azurerm_kubernetes_cluster.this
# first, then re-run terraform apply for the full deployment.

provider "helm" {
  kubernetes {
    host                   = azurerm_kubernetes_cluster.this.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.this.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.this.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate)
  }
}

provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.this.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.this.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.this.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate)
}
