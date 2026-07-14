output "app_gateway_id" {
  description = "Resource ID of the Application Gateway."
  value       = azurerm_application_gateway.this.id
}

output "app_gateway_public_ip" {
  description = "Public IP address of the Application Gateway - this is the address you point DNS (or share with users) at."
  value       = azurerm_public_ip.appgw.ip_address
}

output "waf_policy_id" {
  description = "Resource ID of the WAF policy attached to the Application Gateway."
  value       = azurerm_web_application_firewall_policy.this.id
}
