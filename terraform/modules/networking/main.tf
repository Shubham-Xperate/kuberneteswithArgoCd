# ---------------------------------------------------------------------------
# Networking module
#
# Builds the "landing zone" networking for the e-commerce AKS platform:
#   - one VNet with three purpose-specific subnets (AKS nodes, App Gateway,
#     Private Endpoints)
#   - one NSG per subnet, wired to that subnet
#   - a NAT Gateway attached to the AKS subnet for predictable outbound SNAT
#   - a Private DNS zone for ACR private endpoints, linked to the VNet
#
# Why split into three subnets instead of one flat network?
#   - Application Gateway v2 SKUs require their own **dedicated** subnet
#     (Azure will reject deployment if any other resource type shares it).
#   - Private Endpoints get their own subnet so NSG/route-table rules that
#     apply to "private link traffic" can be scoped tightly and don't have to
#     be reasoned about alongside node/pod traffic.
#   - Keeping AKS nodes in their own subnet lets us size the address space
#     around pod density (Azure CNI) independently of the other tiers.
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.project}-${var.environment}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.project}-${var.environment}"
  address_space       = var.vnet_address_space
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Subnets
# ---------------------------------------------------------------------------

resource "azurerm_subnet" "aks" {
  name                 = "snet-aks"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = var.aks_subnet_address_prefix
}

resource "azurerm_subnet" "appgw" {
  name                 = "snet-appgw"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = var.appgw_subnet_address_prefix
  # NOTE: Do not add any other resource (private endpoints, VMs, etc.) to
  # this subnet. Application Gateway v2 SKUs (WAF_v2 included) require an
  # exclusive subnet - mixing resource types will cause deployment failures.
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = var.private_endpoints_subnet_address_prefix

  # Enable the "private endpoint network policies" so that NSGs and UDRs on
  # this subnet actually apply to private endpoint traffic. Historically
  # this had to be disabled for Private Endpoints to receive an IP at all;
  # it now governs whether NSG/route-table enforcement applies to them, and
  # we want that enforcement active so the NSG rules defined below actually
  # take effect.
  private_endpoint_network_policies_enabled = true
}

# ---------------------------------------------------------------------------
# Network Security Groups
#
# Baseline posture: deny-all-inbound by default (Azure's implicit
# DenyAllInBound rule at priority 65500 already does this - we do not need to
# author it ourselves). We only add explicit ALLOW rules for traffic we know
# must flow, and we keep priorities spaced out (100, 110, 120, ...) so future
# rules can be inserted without renumbering everything.
# ---------------------------------------------------------------------------

resource "azurerm_network_security_group" "aks" {
  name                = "nsg-${var.project}-${var.environment}-aks"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  # Allow the Application Gateway subnet to reach AKS nodes (e.g. NodePort /
  # health-probe traffic to the ingress controller). Scoped to the appgw
  # subnet CIDR rather than "Internet" or "VirtualNetwork" to keep this tight.
  security_rule {
    name                       = "AllowAppGwToAks"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = var.appgw_subnet_address_prefix[0]
    destination_address_prefix = "*"
  }

  # Allow intra-subnet traffic between AKS nodes/pods (kubelet, node-to-node,
  # CNI networking, etc.). Without this, Azure CNI clusters can break in
  # subtle ways because control-plane <-> node and node <-> node traffic is
  # blocked.
  security_rule {
    name                       = "AllowAksInternal"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.aks_subnet_address_prefix[0]
    destination_address_prefix = "*"
  }

  # Everything else inbound falls through to Azure's implicit DenyAllInBound
  # rule (priority 65500). We deliberately do not add an explicit deny rule
  # here - Azure already enforces "deny by default" for anything not
  # explicitly allowed above.
}

resource "azurerm_network_security_group" "appgw" {
  name                = "nsg-${var.project}-${var.environment}-appgw"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  # Required by Azure: Application Gateway v2 uses ports 65200-65535 for
  # internal management traffic between the control plane and gateway
  # instances. If this rule is missing/blocked, the gateway shows an
  # "unhealthy"/failed provisioning state. Source must be GatewayManager.
  security_rule {
    name                       = "AllowGatewayManager"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "65200-65535"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
  }

  # Required for Application Gateway's frontend health probes / load
  # balancing to function when using a Standard/WAF_v2 SKU with a public or
  # internal frontend behind Azure Load Balancer infrastructure.
  security_rule {
    name                       = "AllowAzureLoadBalancer"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  # Allow public internet users to reach the gateway's listeners. In this lab
  # we expose 80 (redirected to 443) and 443 (TLS termination at the
  # gateway/WAF).
  security_rule {
    name                       = "AllowInternetHttpHttps"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "private_endpoints" {
  name                = "nsg-${var.project}-${var.environment}-pe"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  # Only allow traffic originating from inside our own VNet to reach private
  # endpoints. Private Link traffic is already confined to the Microsoft
  # backbone, but this extra rule keeps the subnet's posture explicit and
  # defends against other peered VNets being added later without review.
  security_rule {
    name                       = "AllowVnetInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }
}

# ---------------------------------------------------------------------------
# NSG <-> Subnet associations
# ---------------------------------------------------------------------------

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks.id
  network_security_group_id = azurerm_network_security_group.aks.id
}

resource "azurerm_subnet_network_security_group_association" "appgw" {
  subnet_id                 = azurerm_subnet.appgw.id
  network_security_group_id = azurerm_network_security_group.appgw.id
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

# ---------------------------------------------------------------------------
# NAT Gateway for AKS outbound traffic
#
# Why: by default, AKS nodes get outbound internet access via the Standard
# Load Balancer's default SNAT, which allocates a small, dynamic number of
# SNAT ports per node. Under load (many pods making many outbound
# connections - e.g. calling external APIs, pulling packages), you exhaust
# those ports and start seeing intermittent connection failures that are
# very hard to diagnose. A NAT Gateway gives every outbound flow a large,
# dedicated pool of SNAT ports (up to 64,512 per IP) and a small number of
# static public IPs, making egress predictable and allow-listable by
# downstream firewalls (e.g. a partner API that whitelists your IP).
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "nat_gateway" {
  name                = "pip-${var.project}-${var.environment}-natgw"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard" # NAT Gateway requires Standard SKU public IPs
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

resource "azurerm_nat_gateway" "aks" {
  name                    = "natgw-${var.project}-${var.environment}-aks"
  location                = azurerm_resource_group.this.location
  resource_group_name     = azurerm_resource_group.this.name
  sku_name                = var.nat_gateway_sku_name
  idle_timeout_in_minutes = var.nat_gateway_idle_timeout_minutes
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "aks" {
  nat_gateway_id       = azurerm_nat_gateway.aks.id
  public_ip_address_id = azurerm_public_ip.nat_gateway.id
}

resource "azurerm_subnet_nat_gateway_association" "aks" {
  subnet_id      = azurerm_subnet.aks.id
  nat_gateway_id = azurerm_nat_gateway.aks.id
}

# ---------------------------------------------------------------------------
# Private DNS zone for ACR Private Endpoint
#
# When ACR is reached through a Private Endpoint, DNS resolution of
# "<registry>.azurecr.io" must resolve to the private endpoint's private IP
# (not the registry's public IP) for anything inside the VNet - including
# AKS nodes pulling images. Azure's convention for this is the
# "privatelink.azurecr.io" zone, populated with an A record by the private
# endpoint resource in the acr module, and linked to every VNet that needs
# to resolve it privately.
# ---------------------------------------------------------------------------

resource "azurerm_private_dns_zone" "acr" {
  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr" {
  name                  = "link-${var.project}-${var.environment}-acr"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.acr.name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false # auto-registration is irrelevant/undesired for a Private Link zone
  tags                  = var.tags
}
