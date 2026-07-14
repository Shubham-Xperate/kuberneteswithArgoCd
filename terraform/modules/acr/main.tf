# ---------------------------------------------------------------------------
# Azure Container Registry module
#
# Hosts the .NET API and Angular frontend container images built by CI.
# Exposed only via Private Endpoint (no public network access) so that image
# pulls from AKS never traverse the public internet, and so the registry
# cannot be reached at all from outside the VNet - even with valid
# credentials.
# ---------------------------------------------------------------------------

resource "azurerm_container_registry" "this" {
  # ACR names must be globally unique and alphanumeric only (no hyphens).
  name                = "acr${var.project}${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.sku
  tags                = var.tags

  # Admin credentials are a shared, static username/password with no
  # identity, no audit trail of *which* caller pulled/pushed, and no way to
  # scope permissions. Production access should always go through Azure AD
  # identities instead:
  #   - AKS pulls images via its kubelet managed identity + an AcrPull role
  #     assignment (wired up in the aks module) - no docker login, no
  #     imagePullSecrets.
  #   - CI/CD pipelines push images using a service principal / workload
  #     identity federated credential with AcrPush, not a shared admin
  #     password.
  admin_enabled = false

  # Public network access is disabled - the registry can only be reached via
  # the Private Endpoint created below. Anything that needs to push images
  # (CI/CD runners, developer machines) must run inside the VNet or over a
  # VPN/ExpressRoute/self-hosted-agent that has network line-of-sight to
  # snet-private-endpoints.
  public_network_access_enabled = false
}

# ---------------------------------------------------------------------------
# Private Endpoint
#
# Creates a NIC inside snet-private-endpoints with a private IP that maps to
# this registry's data-plane endpoints. The associated private DNS zone
# group below writes the required A record into privatelink.azurecr.io so
# that "<name>.azurecr.io" resolves to the private IP for anything resolving
# DNS inside the VNet (including AKS nodes).
# ---------------------------------------------------------------------------

resource "azurerm_private_endpoint" "acr" {
  name                = "pe-${var.project}-${var.environment}-acr"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.project}-${var.environment}-acr"
    private_connection_resource_id = azurerm_container_registry.this.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-zone-group-acr"
    private_dns_zone_ids = [var.private_dns_zone_id]
  }
}
