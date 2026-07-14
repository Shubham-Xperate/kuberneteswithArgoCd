variable "project" {
  type        = string
  description = "Short project name used as part of the resource naming convention (e.g. \"ecom\")."
  default     = "ecom"
}

variable "environment" {
  type        = string
  description = "Deployment environment name. Fixed to \"prod\" for this root config."
  default     = "prod"
}

variable "location" {
  type        = string
  description = "Azure region to deploy all resources into."
  default     = "eastus"
}

variable "vnet_address_space" {
  type        = list(string)
  description = "Address space for the VNet."
  default     = ["10.0.0.0/16"]
}

variable "aks_kubernetes_version" {
  type        = string
  description = "Kubernetes version to pin the cluster to. Prod should pin an explicit, tested version rather than floating to AKS's default, so upgrades are a deliberate, reviewed change."
  default     = "1.29"
}

variable "aks_private_cluster_enabled" {
  type        = bool
  description = "Whether the AKS API server is private-only. True in prod - the control plane must not be reachable from the public internet; access goes through a VPN/ExpressRoute/bastion/self-hosted CI runner with VNet line-of-sight."
  default     = true
}

variable "aks_system_node_pool" {
  description = "System node pool sizing for prod - still small since it only hosts cluster add-ons, but spread with autoscaling headroom for resilience."
  type = object({
    vm_size             = string
    node_count          = optional(number)
    enable_auto_scaling = optional(bool, true)
    min_count           = optional(number)
    max_count           = optional(number)
    os_disk_size_gb     = optional(number, 128)
  })
  default = {
    vm_size             = "Standard_D4s_v5"
    node_count          = 3
    enable_auto_scaling = true
    min_count           = 3
    max_count           = 5
  }
}

variable "aks_user_node_pool" {
  description = "User (application workload) node pool sizing for prod - larger SKU and higher max for real production load."
  type = object({
    vm_size             = string
    node_count          = optional(number)
    enable_auto_scaling = optional(bool, true)
    min_count           = optional(number)
    max_count           = optional(number)
    os_disk_size_gb     = optional(number, 128)
    node_labels         = optional(map(string), {})
    node_taints         = optional(list(string), [])
  })
  default = {
    vm_size             = "Standard_D4s_v5"
    node_count          = 3
    enable_auto_scaling = true
    min_count           = 3
    max_count           = 10
    node_labels         = { workload = "app" }
  }
}

variable "appgw_backend_address" {
  type        = string
  description = "Placeholder IP/FQDN for the Application Gateway backend pool - update after deploying an ingress controller into AKS. See modules/appgw-waf/variables.tf for full explanation."
  default     = "10.0.1.100"
}

variable "appgw_waf_mode" {
  type        = string
  description = "WAF policy mode for prod. Prevention actively blocks malicious requests - the expected posture for a production, internet-facing system that has already been through a Detection bake-in in a lower environment."
  default     = "Prevention"
}

variable "appgw_sku_capacity" {
  description = "Autoscale capacity bounds for the prod Application Gateway - higher ceiling to absorb real traffic spikes."
  type = object({
    min = number
    max = number
  })
  default = {
    min = 2
    max = 10
  }
}
