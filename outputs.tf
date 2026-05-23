output "cluster_name" {
  description = "AKS cluster name"
  value       = azurerm_kubernetes_cluster.this.name
}

output "resource_group_name" {
  description = "Resource group containing the AKS cluster"
  value       = azurerm_resource_group.this.name
}

output "location" {
  description = "Azure region used for the deployment"
  value       = var.location
}

output "configure_kubectl" {
  description = "Run this command to configure kubectl for the new cluster"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.this.name} --name ${azurerm_kubernetes_cluster.this.name} --overwrite-existing"
}

output "storage_account_name" {
  description = "Storage account name backing the shared PVC"
  value       = azurerm_storage_account.fortiaigate.name
}

output "release_status" {
  description = "Helm release deployment status"
  value       = helm_release.fortiaigate.status
}

output "ingress_host" {
  description = "Configured ingress hostname (empty = matches all hosts)"
  value       = var.ingress_host
}

data "kubernetes_ingress_v1" "fortiaigate" {
  metadata {
    name      = "fortiaigate-ingress"
    namespace = var.namespace
  }
  depends_on = [helm_release.fortiaigate]
}

output "ingress_address" {
  description = "Application Gateway public/private IP assigned by AGIC — use this to configure the FortiGate and chatbot"
  value = try(
    coalesce(
      data.kubernetes_ingress_v1.fortiaigate.status[0].load_balancer[0].ingress[0].ip,
      data.kubernetes_ingress_v1.fortiaigate.status[0].load_balancer[0].ingress[0].hostname
    ),
    "not yet assigned — run: kubectl get ingress fortiaigate-ingress -n ${var.namespace}"
  )
}
