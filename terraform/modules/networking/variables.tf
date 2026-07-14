variable "project" {
  type        = string
  description = "Short project name used as part of the resource naming convention (e.g. \"ecom\")."
}

variable "environment" {
  type        = string
  description = "Deployment environment name (e.g. \"dev\", \"prod\"). Used in resource naming and tagging."
}

variable "location" {
  type        = string
  description = "Azure region to deploy networking resources into (e.g. \"eastus\", \"westeurope\")."
}

variable "tags" {
  type        = map(string)
  description = "Common tags applied to every resource created by this module. Composed once in the root module so tagging stays consistent across all modules."
}

variable "vnet_address_space" {
  type        = list(string)
  description = "Address space for the VNet. Sized generously (/16) so future subnets can be added without re-IPing the whole network."
  default     = ["10.0.0.0/16"]
}

variable "aks_subnet_address_prefix" {
  type        = list(string)
  description = "Address prefix for the AKS node subnet (snet-aks). Must be large enough to hold node IPs + pod IPs if using Azure CNI (non-overlay)."
  default     = ["10.0.1.0/24"]
}

variable "appgw_subnet_address_prefix" {
  type        = list(string)
  description = "Address prefix for the Application Gateway / WAF subnet (snet-appgw). Application Gateway v2 SKUs require a DEDICATED subnet (no other resource types allowed in it)."
  default     = ["10.0.2.0/24"]
}

variable "private_endpoints_subnet_address_prefix" {
  type        = list(string)
  description = "Address prefix for the subnet hosting Private Endpoints (snet-private-endpoints) to ACR, SQL, etc. Kept isolated from compute subnets for clearer NSG boundaries."
  default     = ["10.0.3.0/24"]
}

variable "nat_gateway_sku_name" {
  type        = string
  description = "SKU for the NAT Gateway. \"Standard\" is currently the only SKU Azure supports for NAT Gateway."
  default     = "Standard"
}

variable "nat_gateway_idle_timeout_minutes" {
  type        = number
  description = "Idle timeout (in minutes) for NAT Gateway outbound flows. Azure default is 4; raised slightly here to reduce SNAT flow churn for long-lived outbound connections (e.g. pulling large container image layers from ACR/Docker Hub)."
  default     = 10
}
