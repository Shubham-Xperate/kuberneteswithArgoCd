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
  description = "Azure region to deploy the cluster into."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group to deploy the AKS cluster into (the networking module's resource group)."
}

variable "tags" {
  type        = map(string)
  description = "Common tags applied to every resource created by this module."
}

variable "aks_subnet_id" {
  type        = string
  description = "ID of the subnet (snet-aks) the system and user node pools will place their nodes into."
}

variable "acr_id" {
  type        = string
  description = "Resource ID of the Azure Container Registry that this cluster must be granted AcrPull on."
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version for the control plane and default node pool. Left unpinned (null) lets Azure pick its current default; pin explicitly for reproducible/prod environments."
  default     = null
}

variable "private_cluster_enabled" {
  type        = bool
  description = "Whether the AKS API server gets a private endpoint instead of a public FQDN. False by default so this lab is reachable with kubectl from a laptop without a VPN/jumpbox; set to true for production so the control plane is never internet-reachable."
  default     = false
}

variable "sku_tier" {
  type        = string
  description = "AKS control plane pricing tier: \"Free\" (no SLA, fine for dev/learning) or \"Standard\" (uptime SLA, recommended for prod)."
  default     = "Free"
}

variable "system_node_pool" {
  description = "Configuration for the default (system) node pool, which should run only critical cluster add-ons (CoreDNS, metrics-server, etc.) - not application workloads."
  type = object({
    vm_size             = string
    node_count          = optional(number)
    enable_auto_scaling = optional(bool, true)
    min_count           = optional(number)
    max_count           = optional(number)
    os_disk_size_gb     = optional(number, 128)
  })
}

variable "user_node_pool" {
  description = "Configuration for the dedicated user node pool that runs the .NET API and Angular frontend workloads, kept separate from the system pool so app scaling/updates never disturb cluster-critical pods."
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
}
