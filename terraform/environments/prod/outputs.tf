output "resource_group_name" {
  description = "Name of the resource group holding all prod resources."
  value       = module.networking.resource_group_name
}

output "vnet_id" {
  description = "ID of the prod VNet."
  value       = module.networking.vnet_id
}

output "acr_login_server" {
  description = "Login server for the prod Azure Container Registry."
  value       = module.acr.acr_login_server
}

output "aks_cluster_name" {
  description = "Name of the prod AKS cluster."
  value       = module.aks.cluster_name
}

output "aks_kube_config_raw" {
  description = "Raw kubeconfig for the prod cluster. Sensitive - since the cluster is private, this will only work from inside the VNet (or a peered/VPN-connected network)."
  value       = module.aks.kube_config_raw
  sensitive   = true
}

output "app_gateway_public_ip" {
  description = "Public IP of the prod Application Gateway."
  value       = module.appgw_waf.app_gateway_public_ip
}
