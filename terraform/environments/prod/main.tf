# ---------------------------------------------------------------------------
# prod environment root module
#
# Same module wiring as dev, but with production-appropriate settings:
# larger/higher-ceiling node pools, a private AKS API server, a pinned
# Kubernetes version, and a Prevention-mode WAF. See variables.tf in this
# directory for the specific defaults, and terraform.tfvars.example for how
# to override them per-subscription.
# ---------------------------------------------------------------------------

locals {
  tags = {
    environment = var.environment
    project     = var.project
    managed_by  = "terraform"
  }
}

module "networking" {
  source = "../../modules/networking"

  project     = var.project
  environment = var.environment
  location    = var.location
  tags        = local.tags

  vnet_address_space = var.vnet_address_space
}

module "acr" {
  source = "../../modules/acr"

  project              = var.project
  environment          = var.environment
  location             = module.networking.location
  resource_group_name  = module.networking.resource_group_name
  tags                 = local.tags

  private_endpoint_subnet_id = module.networking.subnet_ids["private_endpoints"]
  private_dns_zone_id        = module.networking.acr_private_dns_zone_id
}

module "aks" {
  source = "../../modules/aks"

  project              = var.project
  environment          = var.environment
  location             = module.networking.location
  resource_group_name  = module.networking.resource_group_name
  tags                 = local.tags

  aks_subnet_id = module.networking.subnet_ids["aks"]
  acr_id        = module.acr.acr_id

  kubernetes_version      = var.aks_kubernetes_version
  private_cluster_enabled = var.aks_private_cluster_enabled
  sku_tier                = "Standard" # uptime SLA for the control plane in prod

  system_node_pool = var.aks_system_node_pool
  user_node_pool   = var.aks_user_node_pool
}

module "appgw_waf" {
  source = "../../modules/appgw-waf"

  project              = var.project
  environment          = var.environment
  location             = module.networking.location
  resource_group_name  = module.networking.resource_group_name
  tags                 = local.tags

  appgw_subnet_id = module.networking.subnet_ids["appgw"]

  backend_address = var.appgw_backend_address
  waf_mode        = var.appgw_waf_mode
  sku_capacity    = var.appgw_sku_capacity
}
