output "acr_id" {
  description = "Resource ID of the Azure Container Registry, used by the aks module to scope the AcrPull role assignment."
  value       = azurerm_container_registry.this.id
}

output "acr_name" {
  description = "Name of the Azure Container Registry."
  value       = azurerm_container_registry.this.name
}

output "acr_login_server" {
  description = "Login server hostname (e.g. acrecomdev.azurecr.io) used when tagging/pushing/pulling images."
  value       = azurerm_container_registry.this.login_server
}

output "private_endpoint_id" {
  description = "Resource ID of the ACR private endpoint."
  value       = azurerm_private_endpoint.acr.id
}

output "private_endpoint_ip" {
  description = "Private IP address assigned to the ACR private endpoint NIC."
  value       = azurerm_private_endpoint.acr.private_service_connection[0].private_ip_address
}
