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
  description = "Azure region to deploy the Application Gateway into."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group to deploy the Application Gateway into (the networking module's resource group)."
}

variable "tags" {
  type        = map(string)
  description = "Common tags applied to every resource created by this module."
}

variable "appgw_subnet_id" {
  type        = string
  description = "ID of the dedicated Application Gateway subnet (snet-appgw) from the networking module."
}

variable "backend_address" {
  type        = string
  description = <<-EOT
    IP address or FQDN of the backend that receives traffic from the gateway.
    In a fully wired-up deployment this would be the internal IP of AKS's
    ingress controller Service (type: LoadBalancer, internal) or the
    ingress controller's FQDN - but this Terraform project does not
    provision anything *inside* the cluster (no Helm/Kubernetes provider
    resources), so that IP does not exist yet at `terraform apply` time.
    Supply a placeholder here for a first apply, then update this value
    (via tfvars) once your ingress controller has been deployed and has a
    known address, and re-apply.
  EOT
}

variable "waf_mode" {
  type        = string
  description = "WAF policy mode: \"Detection\" only logs matches, \"Prevention\" actively blocks matching requests. Detection is useful during initial rollout to tune false positives before enforcing."
  default     = "Prevention"

  validation {
    condition     = contains(["Detection", "Prevention"], var.waf_mode)
    error_message = "waf_mode must be either \"Detection\" or \"Prevention\"."
  }
}

variable "sku_capacity" {
  description = "Autoscale capacity bounds (in Application Gateway Capacity Units) for the WAF_v2 SKU."
  type = object({
    min = number
    max = number
  })
  default = {
    min = 1
    max = 3
  }
}
