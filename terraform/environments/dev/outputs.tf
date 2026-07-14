output "resource_group_name" {
  description = "Name of the resource group holding all dev resources."
  value       = module.networking.resource_group_name
}

output "vnet_id" {
  description = "ID of the dev VNet."
  value       = module.networking.vnet_id
}

output "acr_login_server" {
  description = "Login server for the dev Azure Container Registry (used when tagging/pushing images from CI)."
  value       = module.acr.acr_login_server
}

output "aks_cluster_name" {
  description = "Name of the dev AKS cluster - use with `az aks get-credentials -g <resource_group_name> -n <this>`."
  value       = module.aks.cluster_name
}

output "aks_kube_config_raw" {
  description = "Raw kubeconfig for the dev cluster. Sensitive."
  value       = module.aks.kube_config_raw
  sensitive   = true
}

output "app_gateway_public_ip" {
  description = "Public IP of the dev Application Gateway - point DNS or browse to this directly."
  value       = module.appgw_waf.app_gateway_public_ip
}
