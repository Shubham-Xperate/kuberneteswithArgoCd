output "cluster_id" {
  description = "Resource ID of the AKS cluster."
  value       = azurerm_kubernetes_cluster.this.id
}

output "cluster_name" {
  description = "Name of the AKS cluster (used with `az aks get-credentials`)."
  value       = azurerm_kubernetes_cluster.this.name
}

output "kube_config_raw" {
  description = "Raw kubeconfig for the cluster's admin credentials. Sensitive - avoid printing in CI logs; prefer `az aks get-credentials` for day-to-day access."
  value       = azurerm_kubernetes_cluster.this.kube_config_raw
  sensitive   = true
}

output "cluster_identity_principal_id" {
  description = "Object ID of the cluster's system-assigned control-plane identity."
  value       = azurerm_kubernetes_cluster.this.identity[0].principal_id
}

output "kubelet_identity_object_id" {
  description = "Object ID of the kubelet identity used by nodes to pull images and call Azure APIs on behalf of pods (the identity granted AcrPull on the registry)."
  value       = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

output "node_resource_group" {
  description = "Name of the auto-created resource group holding the cluster's IaaS resources (VMSS, disks, node NICs, the AKS-managed load balancer, etc.)."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}
