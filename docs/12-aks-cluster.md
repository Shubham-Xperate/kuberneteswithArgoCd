# 12 — Azure Kubernetes Service (AKS)

Doc 06 covered Kubernetes concepts — Pods, Deployments, Services — as things that exist inside *some* cluster, without dwelling on where that cluster itself comes from or who's responsible for keeping it alive. This doc is about that layer: what AKS actually manages for you, what it hands back to you to manage yourself, and why `terraform/modules/aks/main.tf` configures the cluster the specific way it does.

## Managed control plane vs. self-hosted Kubernetes

Every Kubernetes cluster has two conceptual halves. The **control plane** is the cluster's brain: the API server (everything `kubectl` talks to), `etcd` (the datastore holding all cluster state), the scheduler (decides which node a new pod lands on), and the various controllers (like the Deployment controller from doc 06) that continuously reconcile desired state against actual state. The **data plane** is the worker nodes actually running your containers. If you stood up Kubernetes yourself on a pile of VMs — "self-hosted" or "self-managed" Kubernetes — you would be responsible for both halves: patching and upgrading the control plane components, keeping `etcd` backed up and healthy, handling control-plane high availability across failures, and only after all of that, running your own workloads on top.

**AKS (Azure Kubernetes Service)** is a **managed Kubernetes** offering: Azure operates and is responsible for the control plane — you never see, patch, back up, or lose sleep over the API server or `etcd` directly; Azure keeps them running, and Microsoft's own SLA (where applicable, discussed below) applies to their availability. What you're left responsible for is the data plane: sizing, scaling, and patching your own node pools, and, of course, everything you deploy onto them. This is precisely why the Terraform in this project only ever creates `azurerm_kubernetes_cluster` and `azurerm_kubernetes_cluster_node_pool` resources — there is no control-plane infrastructure to provision, because Azure already owns and runs it.

## `sku_tier`: Free vs. Standard, and the SLA it actually buys

`terraform/modules/aks/variables.tf` exposes a `sku_tier` variable, and the two real environments set it differently — dev via a hardcoded value in `terraform/environments/dev/main.tf` (`sku_tier = "Free"`), prod likewise hardcoded to `"Standard"` in `terraform/environments/prod/main.tf`. This setting governs the **control plane's** pricing tier and, with it, whether Azure attaches an uptime SLA to the API server's availability. `Free` carries no formal SLA — entirely reasonable for a dev/learning cluster where an occasional control-plane hiccup costs you a few minutes of `kubectl` being slow to respond, not a production incident. `Standard` is the tier that carries a real uptime commitment, appropriate for production, where control-plane unavailability (even though your already-running pods keep serving traffic during a brief control-plane outage — a detail worth knowing, since the control plane isn't in the request path for already-running Services) still blocks new deployments, autoscaling decisions, and troubleshooting until it's restored.

## Node pools: system vs. user, and why they're isolated

An AKS **node pool** is a group of identically-configured VMs (nodes) backing the cluster — you can have more than one, with different VM sizes, scaling settings, or purposes. This project deliberately creates two, and the reasoning is spelled out directly in `terraform/modules/aks/main.tf`'s comments. The **system node pool** (`default_node_pool`, named `"system"`) is configured with `only_critical_addons_enabled = true`:

```hcl
default_node_pool {
  name                          = "system"
  vm_size                       = var.system_node_pool.vm_size
  vnet_subnet_id                = var.aks_subnet_id
  enable_auto_scaling           = var.system_node_pool.enable_auto_scaling
  only_critical_addons_enabled  = true
  upgrade_settings {
    max_surge = "10%"
  }
}
```

`only_critical_addons_enabled = true` is the setting that actually enforces the isolation: it applies a taint to this node pool's nodes that prevents ordinary application pods from being scheduled onto them at all, reserving this pool exclusively for cluster-critical add-ons — CoreDNS (cluster-internal DNS, covered in doc 06), `metrics-server` (the component that makes CPU/memory metrics available to the Horizontal Pod Autoscaler, see below), konnectivity, and similar system components AKS itself relies on to function. The **user node pool** is a second, separate pool specifically for this project's own workloads:

```hcl
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name           = "user"
  vm_size        = var.user_node_pool.vm_size
  mode           = "User"
  node_labels    = var.user_node_pool.node_labels
  node_taints    = var.user_node_pool.node_taints
  upgrade_settings {
    max_surge = "33%"
  }
}
```

The reason to isolate these rather than run everything on one pool is straightforward once you picture the alternative: if application pods and cluster-critical add-ons shared a node pool, then scaling the application workload up or down, or rolling a node-image upgrade through that pool, would carry a real risk of momentarily disturbing CoreDNS or `metrics-server` — components the whole cluster's normal operation quietly depends on. Isolating them means you can scale, upgrade, or apply a completely different VM size or taint to application nodes with zero risk to the pods keeping the cluster itself functional. Note also the two pools' differing `upgrade_settings.max_surge` values (10% for system, 33% for user) — a smaller surge on the more sensitive system pool means Azure creates fewer extra temporary nodes at once during a rolling upgrade there, a conservative choice for the pool nothing else can afford to have flaky.

## Azure CNI vs. kubenet, and why this project picks Azure CNI

AKS offers two main networking models for how pods get IP addresses. **kubenet** is the simpler, older option: pods get IPs from a separate, internal overlay network that's not part of the VNet's own address space at all, and traffic between pods and the rest of the VNet has to be translated/routed specially — pods are, in a real sense, second-class citizens on the network, invisible to anything that only understands "real" VNet IPs. **Azure CNI (Container Networking Interface)** gives every pod a real, routable IP address allocated directly from the VNet subnet it's running in — pods look, to the rest of the network, exactly like any other VNet-attached resource.

`terraform/modules/aks/main.tf` picks Azure CNI explicitly, and its own comment states the reason plainly: it "matches the VNet-native subnet model used by the networking module, and lets NSGs on `snet-aks` meaningfully see pod IPs." This is the direct, necessary consequence of doc 10's networking design: if you're going to write NSG rules, attach a NAT Gateway, and reason about Private Endpoint traffic all in terms of real VNet IP ranges (as this project's `networking` module does throughout), pods need to actually participate in that address space for any of those controls to mean anything with respect to pod-level traffic. With kubenet, an NSG attached to `snet-aks` would only ever see node IPs, not the pod IPs actually generating or receiving traffic — a real limitation for a design this network-security-conscious. The tradeoff, worth knowing honestly: Azure CNI consumes real VNet address space per pod (which is part of why the subnet address planning in doc 10 sizes `snet-aks` generously), whereas kubenet's overlay approach is more IP-address-frugal — a genuine reason some clusters still choose kubenet, just not one that outweighs this project's networking goals.

```hcl
network_profile {
  network_plugin    = "azure"
  network_policy    = "azure"
  load_balancer_sku = "standard"
  outbound_type     = "loadBalancer"
}
```

`network_policy = "azure"` is a related, separate setting: it's what actually *enforces* Kubernetes `NetworkPolicy` resources (rules restricting which pods can talk to which other pods) using Azure's own network dataplane — Calico is the other common choice for this and supports a broader set of policy features, but Azure's own implementation is simpler to operate and sufficient for this project's needs (standard namespace-level isolation, nothing more exotic).

## Private clusters: why prod uses one and dev doesn't

`private_cluster_enabled` governs whether the AKS **API server** — not the application traffic, the cluster's own control-plane endpoint that `kubectl` talks to — gets a public IP/FQDN at all, or only a private one resolvable from inside the VNet. `terraform/modules/aks/variables.tf`'s own comment states the tradeoff directly: "False by default so this lab is reachable with kubectl from a laptop without a VPN/jumpbox; set to true for production so the control plane is never internet-reachable." Dev sets `aks_private_cluster_enabled = false` specifically so a learner can run `az aks get-credentials` and start using `kubectl` immediately from their own machine, with nothing extra to stand up first. Prod sets it to `true` (`terraform/environments/prod/terraform.tfvars.example`) because, in the recommended production posture, the cluster's control plane — the single most powerful thing an attacker could target, since compromising it means compromising everything running on the cluster — should not be reachable from the public internet at all, even by someone with valid credentials, full stop. In a real production setup with a private cluster, reaching it for day-to-day operations requires being on the VNet already — via a VPN, ExpressRoute, a bastion host, or (very commonly in real Azure DevOps setups) a self-hosted pipeline agent deployed inside the VNet that can run `kubectl`/`helm`/`argocd` commands with network line-of-sight the public internet never has.

## Cluster autoscaler vs. HPA: two layers of scaling

Doc 06 introduced the **Horizontal Pod Autoscaler (HPA)** — a controller that watches a metric (CPU utilization, in this project's `helm/ecommerce-chart/templates/hpa.yaml`) and adjusts the **number of pods** for a Deployment up or down to match load, within `minReplicas`/`maxReplicas` bounds. The HPA answers the question "given the nodes I already have, how many copies of this app should be running right now?" It has an entirely separate counterpart at the infrastructure layer: the **cluster autoscaler**, which answers a different question — "do I have enough *nodes* to actually run all the pods that currently want to be scheduled?" If the HPA decides to scale the API Deployment from 3 pods to 6 under load, and the existing nodes don't have enough spare CPU/memory capacity to actually place those 3 new pods, they sit in a `Pending` state (a scheduling failure covered in doc 15's troubleshooting table) until either something frees up, or the cluster autoscaler notices the unscheduled pods and adds a new node to the pool to make room for them. Scaling back down works symmetrically in both directions: the HPA removes pods as load drops, and the cluster autoscaler, seeing nodes running with little to nothing scheduled on them, removes those now-underused nodes to control cost.

This project enables the cluster autoscaler on both node pools via `enable_auto_scaling` plus `min_count`/`max_count` bounds, visible directly in the tfvars:

```hcl
aks_user_node_pool = {
  vm_size             = "Standard_D2s_v5"
  enable_auto_scaling = true
  min_count           = 1
  max_count           = 3   # dev
  # min_count = 3, max_count = 10 in prod
}
```

and `terraform/modules/aks/main.tf` wires this through conditionally:

```hcl
node_count = var.user_node_pool.node_count
min_count  = var.user_node_pool.enable_auto_scaling ? var.user_node_pool.min_count : null
max_count  = var.user_node_pool.enable_auto_scaling ? var.user_node_pool.max_count : null
```

When autoscaling is enabled, `node_count` is only the pool's *initial* size at creation time — after that, the cluster autoscaler takes over and adjusts the actual node count anywhere between `min_count` and `max_count` based on real scheduling pressure, which is exactly why `min_count`/`max_count` are only passed through when `enable_auto_scaling` is true (with autoscaling off, `node_count` alone is the fixed, permanent size, and passing `min_count`/`max_count` would be meaningless). The two layers — HPA adjusting pod count, cluster autoscaler adjusting node count — operate independently but in service of the same goal, each solving half of "the cluster should always have roughly the right amount of capacity, no more, no less," and understanding them as two separate, cooperating mechanisms rather than one combined "autoscaling" feature is the key thing to take away here.

## Key terms

- **Managed Kubernetes** — a Kubernetes offering (like AKS) where the cloud provider operates and is responsible for the control plane, leaving you responsible only for node pools and workloads.
- **Control plane** — the API server, `etcd`, scheduler, and controllers that manage cluster state; in AKS, operated by Azure.
- **Data plane** — the worker nodes that actually run your containers; in AKS, your responsibility to size and scale.
- **Node pool** — a group of identically-configured VM nodes backing a cluster; AKS supports multiple pools with different sizes/purposes.
- **System vs. user node pool** — a system pool reserved for cluster-critical add-ons (via a taint from `only_critical_addons_enabled`), isolated from a user pool running application workloads.
- **Azure CNI** — an AKS networking mode giving every pod a real, routable IP from the VNet subnet, as opposed to kubenet's separate overlay network.
- **Private cluster** — an AKS configuration where the API server has only a private (VNet-internal) address, never a public one.
- **Cluster autoscaler** — a controller that adds or removes nodes from a node pool based on whether currently unschedulable pods need more capacity, or existing nodes are underused.
- **Horizontal Pod Autoscaler (HPA)** — a controller that adjusts the number of pod replicas for a Deployment based on observed metrics like CPU utilization; operates independently from, but alongside, the cluster autoscaler.
- **SKU tier (AKS)** — the control plane's pricing/SLA tier (`Free` vs. `Standard`), determining whether an uptime SLA applies to the API server.
