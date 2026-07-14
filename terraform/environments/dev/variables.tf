variable "project" {
  type        = string
  description = "Short project name used as part of the resource naming convention (e.g. \"ecom\")."
  default     = "ecom"
}

variable "environment" {
  type        = string
  description = "Deployment environment name. Fixed to \"dev\" for this root config."
  default     = "dev"
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
  description = "Kubernetes version to pin the cluster to. Leave null to use AKS's current default (fine for a dev/learning environment)."
  default     = null
}

variable "aks_private_cluster_enabled" {
  type        = bool
  description = "Whether the AKS API server is private-only. False in dev so you can reach it directly with kubectl while learning, without a VPN/bastion."
  default     = false
}

variable "aks_system_node_pool" {
  description = "System node pool sizing for dev - small and fixed, since dev doesn't need to absorb production load."
  type = object({
    vm_size             = string
    node_count          = optional(number)
    enable_auto_scaling = optional(bool, true)
    min_count           = optional(number)
    max_count           = optional(number)
    os_disk_size_gb     = optional(number, 128)
  })
  default = {
    vm_size             = "Standard_D2s_v5"
    node_count          = 1
    enable_auto_scaling = true
    min_count           = 1
    max_count           = 2
  }
}

variable "aks_user_node_pool" {
  description = "User (application workload) node pool sizing for dev."
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
    vm_size             = "Standard_D2s_v5"
    node_count          = 1
    enable_auto_scaling = true
    min_count           = 1
    max_count           = 3
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
  description = "WAF policy mode for dev. Detection is a reasonable default here so you can observe what the managed rule set flags without breaking your own testing traffic."
  default     = "Detection"
}

variable "appgw_sku_capacity" {
  description = "Autoscale capacity bounds for the dev Application Gateway - kept small to control cost."
  type = object({
    min = number
    max = number
  })
  default = {
    min = 1
    max = 2
  }
}
