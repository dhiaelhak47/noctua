output "resource_group_name" {
  value = azurerm_resource_group.noctua.name
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.noctua.name
}

output "kube_config_command" {
  description = "Run this to configure kubectl for the AKS cluster."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.noctua.name} --name ${azurerm_kubernetes_cluster.noctua.name} --overwrite-existing"
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL for Azure Workload Identity federation."
  value       = azurerm_kubernetes_cluster.noctua.oidc_issuer_url
}

output "kubelet_identity_object_id" {
  description = "Object ID of the kubelet managed identity (for ACR pull role assignment)."
  value       = azurerm_kubernetes_cluster.noctua.kubelet_identity[0].object_id
}
