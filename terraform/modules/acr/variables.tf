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
  description = "Azure region to deploy the registry and its private endpoint into."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group to deploy ACR and its private endpoint into (the networking module's resource group, so everything for this environment lives together)."
}

variable "tags" {
  type        = map(string)
  description = "Common tags applied to every resource created by this module."
}

variable "private_endpoint_subnet_id" {
  type        = string
  description = "ID of the subnet the ACR private endpoint's NIC will be attached to (snet-private-endpoints from the networking module)."
}

variable "private_dns_zone_id" {
  type        = string
  description = "ID of the privatelink.azurecr.io private DNS zone (from the networking module) that the private endpoint will register its A record into."
}

variable "sku" {
  type        = string
  description = "ACR SKU. Must be \"Premium\" - Private Endpoints, geo-replication, and higher throughput/image counts are Premium-only features."
  default     = "Premium"

  validation {
    condition     = var.sku == "Premium"
    error_message = "Private Endpoints require the Premium ACR SKU."
  }
}
