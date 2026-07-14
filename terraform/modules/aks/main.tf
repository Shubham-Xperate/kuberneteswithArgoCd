# ---------------------------------------------------------------------------
# AKS module
#
# Provisions the Kubernetes cluster that runs the .NET API and Angular
# frontend. Key design choices, explained inline below:
#   - Azure CNI networking + Azure Network Policy (matches the VNet-native
#     subnet model used by the networking module, and lets NSGs on
#     snet-aks meaningfully see pod IPs).
#   - System-assigned managed identity for the cluster, plus the separately
#     managed kubelet identity, used to grant AcrPull on the registry -
#     replacing docker login / imagePullSecrets entirely.
#   - A dedicated user node pool, isolated from the system node pool, for
#     application workloads.
# ---------------------------------------------------------------------------

resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${var.project}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = "aks-${var.project}-${var.environment}"
  kubernetes_version  = var.kubernetes_version
  tags                = var.tags

  sku_tier = var.sku_tier

  # Private cluster: when true, the API server gets only a private FQDN
  # resolvable inside the VNet (via an Azure-managed private DNS zone),
  # never a public IP. This is the recommended production posture - the
  # control plane should not be reachable from the internet at all, even
  # with valid credentials. It is off by default in this lab so a learner
  # can `az aks get-credentials` and run kubectl straight from a laptop
  # without standing up a VPN/jumpbox/bastion first.
  private_cluster_enabled = var.private_cluster_enabled

  # System-assigned identity: Azure creates and manages an Azure AD identity
  # for the cluster's control plane (used for things like managing the
  # node resource group, LB, disks, etc.). This avoids ever having to store
  # a service principal secret for cluster operations.
  identity {
    type = "SystemAssigned"
  }

  default_node_pool {
    name                = "system"
    vm_size             = var.system_node_pool.vm_size
    vnet_subnet_id      = var.aks_subnet_id
    os_disk_size_gb     = var.system_node_pool.os_disk_size_gb
    enable_auto_scaling = var.system_node_pool.enable_auto_scaling

    # When autoscaling is enabled, `node_count` is only the *initial* size;
    # min/max drive the autoscaler afterwards. When disabled, node_count is
    # the fixed size.
    node_count = var.system_node_pool.node_count
    min_count  = var.system_node_pool.enable_auto_scaling ? var.system_node_pool.min_count : null
    max_count  = var.system_node_pool.enable_auto_scaling ? var.system_node_pool.max_count : null

    # Only the system pool should host cluster-critical add-ons; app
    # workloads are scheduled onto the dedicated user pool below. This
    # keeps node pool upgrades/scaling of application workloads from ever
    # disturbing CoreDNS, metrics-server, konnectivity, etc.
    only_critical_addons_enabled = true

    upgrade_settings {
      max_surge = "10%"
    }

    tags = var.tags
  }

  network_profile {
    # Azure CNI gives every pod a routable IP directly from the VNet
    # subnet (as opposed to kubenet's overlay network). This makes pods
    # first-class citizens on the network - which matters here because
    # NSGs, the NAT Gateway, and Private Endpoints in this design all
    # reason about real VNet IP ranges.
    network_plugin = "azure"

    # Azure Network Policy enforces Kubernetes NetworkPolicy resources
    # (pod-to-pod traffic rules) using Azure's own dataplane. Calico is the
    # other common choice and supports a superset of policy features
    # (e.g. global network policies), but Azure's implementation is
    # simpler to operate and sufficient for standard namespace-isolation
    # policies, which is all this e-commerce app needs.
    network_policy = "azure"

    load_balancer_sku = "standard"

    # Outbound internet traffic from nodes/pods is actually governed by the
    # NAT Gateway that the networking module associates directly with
    # snet-aks (azurerm_subnet_nat_gateway_association.aks) - that
    # association takes effect at the subnet level regardless of AKS's own
    # outbound_type setting. We leave outbound_type at AKS's default,
    # "loadBalancer", because we are NOT asking AKS to provision/manage a
    # NAT Gateway itself (that would be outbound_type = "managedNATGateway"
    # for an AKS-owned NAT Gateway, or "userAssignedNATGateway" for a
    # bring-your-own one referenced directly on the cluster). Here the NAT
    # Gateway is owned by the networking module and attached at the subnet
    # level, which silently takes priority over the load balancer for
    # egress once present - a subtlety worth remembering when troubleshooting
    # "why isn't my egress IP what I expect" issues.
    outbound_type = "loadBalancer"
  }
}

# ---------------------------------------------------------------------------
# Dedicated user node pool for application workloads
#
# Separating "system" (cluster add-ons) from "user" (app workloads) node
# pools means you can scale, upgrade, or apply different VM sizes/taints to
# application nodes without any risk of disrupting cluster-critical pods,
# and lets you bin-pack the .NET API / Angular frontend onto right-sized SKUs
# independently of what the control plane needs for its own add-ons.
# ---------------------------------------------------------------------------

resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.user_node_pool.vm_size
  vnet_subnet_id        = var.aks_subnet_id
  os_disk_size_gb       = var.user_node_pool.os_disk_size_gb
  enable_auto_scaling   = var.user_node_pool.enable_auto_scaling
  mode                  = "User"

  node_count = var.user_node_pool.node_count
  min_count  = var.user_node_pool.enable_auto_scaling ? var.user_node_pool.min_count : null
  max_count  = var.user_node_pool.enable_auto_scaling ? var.user_node_pool.max_count : null

  node_labels = var.user_node_pool.node_labels
  node_taints = var.user_node_pool.node_taints

  upgrade_settings {
    max_surge = "33%"
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# AcrPull role assignment for the kubelet identity
#
# AKS clusters using a managed identity have TWO identities:
#   1. The cluster identity (azurerm_kubernetes_cluster.this.identity) -
#      used by the control plane to manage Azure resources (LB, disks...).
#   2. The kubelet identity (identity.0.kubelet_identity) - used by the
#      *nodes* to pull container images and interact with Azure APIs on
#      behalf of running pods.
#
# Granting AcrPull to the kubelet identity is what allows
# `kubectl apply` manifests referencing images in our private ACR to pull
# successfully with ZERO credentials anywhere in the cluster - no
# imagePullSecrets, no `docker login`, nothing to rotate or leak. This is
# the standard, recommended AKS <-> ACR integration pattern (equivalent to
# what `az aks update --attach-acr` does under the hood).
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id

  # Role assignments against a registry can be evaluated before the
  # kubelet identity is fully propagated in Azure AD; a short-lived
  # inconsistency is normal and Terraform's own retry/backoff on
  # role-assignment creation typically handles it without extra config.
}
