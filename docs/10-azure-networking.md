# 10 — Azure Networking: VNets, Subnets, NSGs, NAT, Private Link, and WAF

This is the densest doc in the series, because networking is the layer where a huge fraction of real-world "why won't this connect" debugging happens, and because the project's Terraform (`terraform/modules/networking` and `terraform/modules/appgw-waf`) makes a series of deliberate, non-default choices that only make sense once you understand the concepts underneath them. Read this doc slowly; the payoff is a genuinely transferable mental model, not just facts about this one project.

## Virtual Networks: an isolated private address space

A **Virtual Network (VNet)** is a private, isolated network inside Azure — conceptually the cloud equivalent of the network switch and address plan you'd set up in a physical office, except software-defined and scoped to your subscription. Nothing outside a VNet can reach anything inside it by IP address unless you explicitly allow it (via public endpoints, peering, VPN, or the internet-facing edge resources this doc covers below). The real `terraform/modules/networking/main.tf` creates exactly one:

```hcl
resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.project}-${var.environment}"
  address_space       = var.vnet_address_space
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}
```

with `var.vnet_address_space` defaulting to `["10.0.0.0/16"]`. That `/16` is **CIDR notation** (Classless Inter-Domain Routing) — a compact way of writing an IP address range as a starting address plus a number of fixed bits. `10.0.0.0/16` means "the first 16 bits of the 32-bit address are fixed at `10.0`, and the remaining 16 bits can be anything," which works out to every address from `10.0.0.0` through `10.0.255.255` — 65,536 addresses total. The variable's own comment explains the choice: it's sized generously precisely so more subnets can be carved out later without having to re-plan the whole address space, a mistake that's genuinely painful to fix once a network is in production use (re-IPing a live network means touching every resource attached to it).

## Subnets: why subdivide a VNet at all

A **subnet** is a smaller, named slice of a VNet's address space — `10.0.1.0/24` (256 addresses) carved out of the larger `10.0.0.0/16`, for example. The reason to subdivide rather than put everything in one flat address range is twofold: **segmentation** (different classes of resource get different security rules and different network behaviors applied to them, and a subnet boundary is what those rules attach to) and, in Azure specifically, **delegation** (certain resource types outright require their own dedicated subnet and will refuse to deploy anywhere else). This project uses three subnets, each for a distinct reason:

```hcl
resource "azurerm_subnet" "aks" {
  name             = "snet-aks"
  address_prefixes = var.aks_subnet_address_prefix  # 10.0.1.0/24
}

resource "azurerm_subnet" "appgw" {
  name             = "snet-appgw"
  address_prefixes = var.appgw_subnet_address_prefix  # 10.0.2.0/24
  # NOTE: Application Gateway v2 SKUs require an exclusive subnet -
  # mixing resource types will cause deployment failures.
}

resource "azurerm_subnet" "private_endpoints" {
  name             = "snet-private-endpoints"
  address_prefixes = var.private_endpoints_subnet_address_prefix  # 10.0.3.0/24
  private_endpoint_network_policies_enabled = true
}
```

`snet-aks` holds every AKS node (and, because this project uses Azure CNI, every pod IP too — more on that in doc 12) and is sized to accommodate both. `snet-appgw` is genuinely non-negotiable as its own subnet: Azure's Application Gateway v2 SKU family (which includes the `WAF_v2` SKU this project uses) will reject deployment if any other resource type shares its subnet — this is an Azure platform constraint, not a stylistic choice this project made. `snet-private-endpoints` hosts the network interfaces created when a resource (ACR, and in a fuller build-out, Azure SQL) is exposed via Private Link — keeping these on their own subnet means NSG and route-table rules governing "traffic destined for a private endpoint" can be reasoned about and audited independently of node/pod traffic, rather than tangled together in one subnet's rule set.

## Network Security Groups: a stateful firewall, deny-by-default

A **Network Security Group (NSG)** is Azure's basic firewall, attached to a subnet (or individual network interface) and evaluated against every packet crossing that boundary. Two properties are essential to understand before reading any specific rule. First, NSGs are **stateful**: if an inbound rule allows a connection in, the corresponding outbound return traffic for that same connection is automatically allowed back out — you don't need to author a matching outbound rule for every inbound one, the way you would with a purely stateless packet filter. Second, and this is the property the project's own comments lean on heavily: Azure NSGs are **deny-by-default**. Every NSG has an implicit, unwritten rule at priority 65500 that denies all inbound traffic not explicitly allowed by something with a lower (higher-priority) number, so the *absence* of a rule is itself a meaningful, safe default — you only need to author explicit **allow** rules for traffic you know must flow, and everything else is blocked without you having to write a catch-all deny rule yourself.

`terraform/modules/networking/main.tf` applies exactly this pattern to all three subnets, with priorities deliberately spaced out (100, 110, 120...) so future rules can be inserted without renumbering everything. The AKS NSG:

```hcl
security_rule {
  name                       = "AllowAppGwToAks"
  priority                   = 100
  direction                  = "Inbound"
  protocol                   = "Tcp"
  destination_port_ranges    = ["80", "443"]
  source_address_prefix      = var.appgw_subnet_address_prefix[0]  # scoped, not "Internet"
}
security_rule {
  name                       = "AllowAksInternal"
  priority                   = 110
  direction                  = "Inbound"
  protocol                   = "*"
  source_address_prefix      = var.aks_subnet_address_prefix[0]
}
```

The first rule allows only the App Gateway subnet's specific CIDR to reach AKS on 80/443 — not "Internet," not "VirtualNetwork" — keeping the allowed source as narrow as the actual traffic pattern requires. The second allows intra-subnet traffic among AKS nodes/pods themselves, which the comment flags as necessary for Azure CNI clusters to function correctly (kubelet-to-kubelet, node-to-node, and CNI dataplane traffic all needs this). Neither rule needs an explicit deny counterpart — the implicit `DenyAllInBound` at 65500 already covers everything else.

The App Gateway NSG is the one place this project needs Azure-specific **service tags** rather than IP ranges, because the traffic in question originates from Azure's own managed infrastructure rather than a fixed, knowable address:

```hcl
security_rule {
  name                   = "AllowGatewayManager"
  priority               = 100
  destination_port_range = "65200-65535"
  source_address_prefix  = "GatewayManager"
}
security_rule {
  name                   = "AllowAzureLoadBalancer"
  priority               = 110
  source_address_prefix  = "AzureLoadBalancer"
}
```

`GatewayManager` is required because Application Gateway v2 uses ports 65200–65535 for control-plane traffic between Azure's management layer and the gateway instances themselves — without this rule, the gateway reports an unhealthy or failed provisioning state, a genuinely common real-world troubleshooting trap for people hand-authoring NSGs without knowing this requirement exists. `AzureLoadBalancer` is required for the platform's own health probes and load-balancing infrastructure sitting in front of the gateway's frontend to function. Both are Azure **service tags** — named aliases Azure resolves internally to the actual, changing set of IPs its own infrastructure uses, so you never have to track or update those IPs yourself.

## NAT Gateway: SNAT, port exhaustion, and why this project adds one

To understand why a NAT Gateway exists here, you first need to understand **SNAT (Source Network Address Translation)**. When a pod inside `snet-aks` (a private address like `10.0.1.15`) makes an outbound call to a public internet address, that private IP isn't routable on the public internet — some gateway device has to rewrite the packet's source address to a public IP before it leaves Azure, and rewrite the reply back on the way in. That rewriting is SNAT, and by default in AKS it's performed by the Standard Load Balancer that fronts the cluster. The concrete problem is that a Load Balancer's default SNAT allocation gives each node only a small, fixed number of SNAT ports (the combination of a public IP and a port number is what actually identifies one outbound connection uniquely) — and every simultaneous outbound connection consumes one. Picture pods making many concurrent short-lived calls to external APIs, or many pods pulling packages during a busy CI-triggered deploy: it's entirely possible to exhaust the available SNAT ports on a node, at which point *new* outbound connections start failing intermittently and unpredictably — a failure mode that's notoriously hard to diagnose because it looks like flaky external services rather than an internal networking limit.

A **NAT Gateway** fixes this by being a purpose-built resource for exactly this job: attached at the subnet level, it gives every outbound flow from that subnet a much larger, dedicated pool of SNAT ports (up to 64,512 per allocated public IP), and it does so through a small number of static public IPs rather than the Load Balancer's shared, less predictable allocation. That static-IP property has a second, practical benefit beyond capacity: if a partner API or external service requires IP allow-listing, a NAT Gateway gives you a small, fixed, known set of egress IPs to hand them, instead of an address that could shift. The real Terraform:

```hcl
resource "azurerm_public_ip" "nat_gateway" {
  allocation_method = "Static"
  sku               = "Standard"  # NAT Gateway requires Standard SKU public IPs
  zones             = ["1", "2", "3"]
}
resource "azurerm_nat_gateway" "aks" {
  sku_name                = var.nat_gateway_sku_name  # "Standard" - only SKU Azure currently supports
  idle_timeout_in_minutes = var.nat_gateway_idle_timeout_minutes  # raised to 10 to reduce flow churn for long image pulls
}
resource "azurerm_subnet_nat_gateway_association" "aks" {
  subnet_id      = azurerm_subnet.aks.id
  nat_gateway_id = azurerm_nat_gateway.aks.id
}
```

One subtlety worth internalizing, called out directly in `terraform/modules/aks/main.tf`'s own comments: this NAT Gateway is associated at the **subnet** level, entirely outside of AKS's own `network_profile.outbound_type` setting (which stays at its default, `loadBalancer`, because this project isn't asking AKS itself to own/manage a NAT Gateway — that would be a different setting, `managedNATGateway` or `userAssignedNATGateway`). A subnet-level NAT Gateway association silently takes priority over the Load Balancer for egress once it's present, regardless of what the AKS resource's own outbound setting says — a genuinely common source of confusion when troubleshooting "why is my outbound traffic not coming from the IP I expected."

## Private Endpoints, Private Link, and Private DNS Zones

Even with NSGs restricting *who* can reach a resource, a resource with a **public endpoint** — a public IP address, reachable in principle from anywhere on the internet, with access controlled only by credentials and firewall rules — is still, by definition, exposed to the entire internet's traffic (and its entire population of scanners and attackers) at the network layer, even if every actual request without valid credentials gets rejected. For a container registry holding your production images, or a database holding customer data, "reachable at all from the public internet, but protected by auth" is a meaningfully weaker posture than "not reachable from the public internet, period." **Private Link / Private Endpoints** solve this by giving the resource a genuinely private IP address, inside your own VNet, connected to the resource's backend over Microsoft's internal network backbone rather than the public internet at any point.

This project's ACR module wires up a Private Endpoint explicitly for this reason:

```hcl
resource "azurerm_container_registry" "this" {
  admin_enabled                 = false
  public_network_access_enabled = false  # unreachable from outside the VNet, even with valid credentials
}

resource "azurerm_private_endpoint" "acr" {
  subnet_id = var.private_endpoint_subnet_id  # snet-private-endpoints
  private_service_connection {
    private_connection_resource_id = azurerm_container_registry.this.id
    subresource_names              = ["registry"]
  }
  private_dns_zone_group {
    private_dns_zone_ids = [var.private_dns_zone_id]
  }
}
```

With `public_network_access_enabled = false`, the registry genuinely cannot be reached from the public internet at all — not "reached but denied," but no route to it exists outside the VNet. The remaining puzzle is DNS: an AKS node pulling an image still asks for `youracr.azurecr.io` by that public-looking hostname, because that's what's baked into the Helm chart's `values.yaml` (`api.image.repository: youracr.azurecr.io/ecommerce-api`) — it has no idea a private endpoint even exists. Left alone, that hostname would resolve via public DNS to the registry's public IP, which now (correctly) refuses the connection. The fix is a **Private DNS Zone** — a DNS zone, linked to your VNet, that *overrides* what specific hostnames resolve to for anything doing DNS lookups from inside that VNet. Azure's established convention for ACR is a zone literally named `privatelink.azurecr.io`:

```hcl
resource "azurerm_private_dns_zone" "acr" {
  name = "privatelink.azurecr.io"
}
resource "azurerm_private_dns_zone_virtual_network_link" "acr" {
  private_dns_zone_name = azurerm_private_dns_zone.acr.name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false  # auto-registration is irrelevant for a Private Link zone
}
```

The private endpoint's own `private_dns_zone_group` block (in the `acr` module, shown above) is what actually writes the A record into this zone once the endpoint is created, mapping `youracr.azurecr.io` to the private endpoint's private IP address for exactly this VNet. The net effect: a pod inside `snet-aks` asking for `youracr.azurecr.io` gets back a `10.0.3.x` address instead of a public one, and its traffic to ACR never leaves Azure's private backbone, let alone touches the public internet — while anyone or anything outside this VNet asking for the same hostname still gets the normal public DNS answer (which, since `public_network_access_enabled = false`, leads nowhere useful anyway).

## Load Balancers: Layer 4 vs. Layer 7, and why this project uses Application Gateway

A **Standard Load Balancer** operates at **Layer 4** (the transport layer, in OSI terms) — it distributes traffic based on IP address and port, with no understanding of what's actually inside the packets beyond that. It's fast and simple, and AKS uses one automatically (as covered above, for both inbound Service-type-LoadBalancer traffic and, by default, outbound SNAT). An **Application Gateway** operates at **Layer 7** (the application layer) — it understands HTTP/HTTPS specifically, and can make routing decisions based on the actual request: path, hostname, headers. This project's edge uses Application Gateway rather than a plain Layer 4 load balancer for a specific reason directly relevant to security: Layer 7 awareness is a prerequisite for **TLS termination** (decrypting HTTPS so the traffic can actually be inspected) and for **WAF** functionality, both of which require understanding HTTP requests as HTTP requests, not just as opaque streams of bytes on a port.

## WAF: OWASP Top 10, Detection vs. Prevention, WAF_v2

A **Web Application Firewall (WAF)** inspects HTTP requests against a set of rules designed to catch common attack patterns before they ever reach your application code. The **OWASP Top 10** is an industry-standard, regularly updated list of the most critical web application security risks; two of its long-standing entries are illustrative of what a WAF's managed rules actually look for. **SQL injection (SQLi)** is an attack where user input is crafted so that, if concatenated unsafely into a database query, it changes the query's meaning — a request body containing something like `' OR '1'='1` is a classic, simplified example of a payload a WAF's rule set would recognize as suspicious. **Cross-site scripting (XSS)** is an attack where user input containing executable script (e.g. `<script>...</script>`) gets reflected back into a page and executes in another user's browser, potentially stealing their session. A WAF doesn't replace writing safe code (parameterized queries, output encoding) — it's a defense-in-depth layer that catches many such attempts at the network edge, before they ever reach the application, including against vulnerabilities you don't yet know your own code has.

`terraform/modules/appgw-waf/main.tf` configures exactly this, using Azure's managed rule set:

```hcl
resource "azurerm_web_application_firewall_policy" "this" {
  policy_settings {
    enabled            = true
    mode               = var.waf_mode
    request_body_check = true
  }
  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
  }
}
```

`mode` is the field that determines whether detected attacks are actually stopped. **Detection** mode evaluates every request against the rule set and *logs* matches, but never blocks anything — useful as a bake-in period for a new site, so you can review what the rule set flags and identify false positives (legitimate traffic that happens to resemble an attack pattern) before you risk blocking real users. **Prevention** mode actively blocks matching requests, at the cost that any false positive you haven't already found during a Detection period now affects real traffic live. This project's own tfvars make the environment-appropriate choice explicit: dev defaults to `Detection` (`appgw_waf_mode = "Detection"` in `terraform/environments/dev/terraform.tfvars.example`), appropriate for a learning/testing environment where you want visibility without risk of your own test traffic getting blocked; prod defaults to `Prevention` (`terraform/environments/prod/terraform.tfvars.example`), appropriate for a system presented as production-grade that has, in principle, already been through its Detection bake-in. `WAF_v2` (as opposed to the older `WAF v1` SKU) is required specifically for autoscaling, zone redundancy, and per-site WAF policies — all treated as baseline requirements for a production-grade internet-facing gateway in this design.

## The full packet journey, end to end

**A browser request reaching a pod.** A user's browser resolves your domain to the Application Gateway's public IP (`azurerm_public_ip.appgw`) and opens an HTTPS connection. The gateway's `listener-https` accepts it (its plaintext `listener-http` counterpart exists solely to issue a permanent redirect to HTTPS, per `redirect_configuration` in the real Terraform — the gateway should never serve unencrypted traffic to end users). The WAF policy attached to the gateway inspects the request against the OWASP Core Rule Set before it's allowed to proceed. Assuming it passes, the gateway's `request_routing_rule` forwards it to the backend pool, which is configured with `var.backend_address` — in a fully wired-up deployment, this is the internal IP of the NGINX Ingress Controller's Service (type `LoadBalancer`, internal-only) living inside `snet-aks`. The NGINX Ingress Controller (covered in doc 06) receives the request, matches it against Ingress rules by hostname/path, and forwards it to the appropriate Kubernetes Service, which load-balances it to one of the matching pods.

**A pod pulling an image from ACR.** A pod scheduling onto an AKS node triggers an image pull. The node resolves `youracr.azurecr.io` — because it's inside the VNet, this resolution is overridden by the linked `privatelink.azurecr.io` Private DNS Zone, returning the private endpoint's IP in `snet-private-endpoints` (something like `10.0.3.x`) rather than any public address. The pull request travels over Azure's private backbone via Private Link to the registry's backend — at no point does this traffic traverse the public internet, and (as covered in doc 11) authentication happens via the node's kubelet managed identity rather than any stored credential.

**A pod's outbound call to the public internet.** A pod making a legitimate external call (say, hitting a third-party payment API) sends its packet toward that public address. Because `snet-aks` has the NAT Gateway associated with it, that association takes priority for egress: the NAT Gateway performs SNAT, rewriting the pod's private source IP to one of its own static public IPs before the packet leaves Azure, with a large dedicated pool of SNAT ports backing that translation so many simultaneous outbound connections from many pods don't collide or exhaust available ports.

## Key terms

- **VNet (Virtual Network)** — an isolated, private, software-defined network inside Azure; nothing outside it can reach resources inside it by IP without explicit configuration.
- **CIDR notation** — a way of expressing an IP address range as a base address plus a prefix length (e.g. `/16`), indicating how many leading bits are fixed.
- **Subnet** — a subdivision of a VNet's address space, used for segmentation and, for some Azure resource types, mandatory delegation.
- **NSG (Network Security Group)** — a stateful, deny-by-default firewall attached to a subnet or NIC, evaluated via explicit, prioritized allow/deny rules.
- **Service tag** — a named alias (e.g. `GatewayManager`, `AzureLoadBalancer`, `Internet`) Azure resolves internally to a changing set of IPs belonging to its own managed infrastructure, used in NSG rules instead of hardcoded IPs.
- **SNAT (Source Network Address Translation)** — rewriting a private source IP to a public one so outbound traffic can traverse the public internet and replies can find their way back.
- **SNAT port exhaustion** — running out of available (public IP, port) combinations for concurrent outbound connections, causing new connections to fail intermittently.
- **NAT Gateway** — a dedicated Azure resource providing a large, predictable pool of SNAT ports and a small set of static public IPs for a subnet's outbound traffic.
- **Private Endpoint** — a network interface with a private IP, inside your VNet, that connects to a specific Azure resource's backend over Microsoft's private network rather than the public internet.
- **Private Link** — the underlying Azure service enabling Private Endpoints to reach PaaS resources (ACR, SQL, etc.) privately.
- **Private DNS Zone** — a DNS zone linked to a VNet that overrides specific hostnames' resolution for anything querying DNS from inside that VNet, redirecting public-looking hostnames to private IPs.
- **Layer 4 vs. Layer 7** — network layers referring to transport-level (IP/port) awareness versus application-level (HTTP path/header/host) awareness; determines what a load balancer can and can't inspect or route on.
- **WAF (Web Application Firewall)** — a Layer 7 security control inspecting HTTP requests against known attack patterns before they reach the application.
- **OWASP Top 10** — an industry-standard list of the most critical web application security risks (e.g. SQL injection, XSS), used as the basis for managed WAF rule sets.
- **Detection vs. Prevention mode** — a WAF configuration determining whether matched requests are only logged (Detection) or actively blocked (Prevention).
