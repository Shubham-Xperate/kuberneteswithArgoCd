# 11 — Azure Container Registry (ACR)

## Why a private registry instead of Docker Hub

Every image this project builds — the .NET API, the Angular/nginx frontend — has to live somewhere between "built by CI" and "pulled by AKS to run." Docker Hub, the default public registry most people encounter first, is a reasonable place to publish genuinely open-source images meant for anyone to use, but it's a poor fit for a company's own application images, for three concrete reasons. **Security**: a public repository on Docker Hub is, by definition, pullable by anyone who knows or guesses its name unless you pay for and correctly configure a private repository there — and even then, you're trusting a third party's access-control implementation for something that might contain your compiled application logic, and potentially, if someone's careless with a Dockerfile, leftover secrets baked into a layer. **Reliability**: Docker Hub enforces rate limits on pulls (historically tightened multiple times, catching teams off guard mid-incident when a cluster tries to reschedule many pods at once and gets throttled), and an outage on Docker Hub's end becomes an outage for your own deployments with no ability to do anything about it on your side. **Compliance**: many regulatory and enterprise security frameworks require that a company's own source-derived artifacts stay within infrastructure the company controls and can audit — "our production images live on a third-party public registry" is a difficult sentence to defend in a security review. A **private registry you own** — Azure Container Registry, in this project — sidesteps all three: you control exactly who can push and pull, you're not subject to a shared public service's rate limits, and the artifacts never leave infrastructure under your own subscription's governance.

## The real ACR module: Premium SKU and why it's required here

`terraform/modules/acr/main.tf` provisions the registry at a specific, enforced SKU:

```hcl
resource "azurerm_container_registry" "this" {
  name                = "acr${var.project}${var.environment}"
  sku                 = var.sku
  admin_enabled                 = false
  public_network_access_enabled = false
}
```

and `terraform/modules/acr/variables.tf` doesn't just default `sku` to `"Premium"` — it enforces it with a `validation` block that fails `terraform plan` outright if you try anything else:

```hcl
variable "sku" {
  type        = string
  description = "ACR SKU. Must be \"Premium\" - Private Endpoints, geo-replication, and higher throughput/image counts are Premium-only features."
  default     = "Premium"

  validation {
    condition     = var.sku == "Premium"
    error_message = "Private Endpoints require the Premium ACR SKU."
  }
}
```

This is worth understanding rather than just accepting: Azure sells ACR in Basic, Standard, and Premium tiers, and **Private Endpoints are a Premium-only capability** — Basic and Standard registries can only be reached over the public internet (with `public_network_access_enabled` locked to allowing public access), full stop, regardless of what NSG rules you write elsewhere. Since doc 10 establishes that this project's entire design goal is "AKS nodes pull images without ever touching the public internet," Premium isn't an optional upgrade for extra features here — it's a hard prerequisite for the architecture to work at all. Premium also unlocks **geo-replication** (running the same registry, kept in sync, across multiple Azure regions, so a multi-region AKS deployment can pull from a nearby replica instead of one, potentially distant, region) — not used in this project's current single-region setup, but worth knowing about as the natural next step if this were extended to a multi-region production deployment. The registry name itself, `acr${var.project}${var.environment}`, follows a real Azure constraint the comment calls out directly: ACR names must be globally unique across all of Azure and alphanumeric only, no hyphens — a small but common gotcha the first time you try to name one.

## Image tagging strategy: why `$(Build.BuildId)` beats `latest`

The pipeline (covered in full in doc 13) tags every image it builds with `$(Build.BuildId)` — Azure DevOps's own immutable, monotonically increasing integer identifying that specific pipeline run — rather than the far more common but genuinely harmful default of `:latest`. The pipeline's own comment spells out exactly why, and it's worth repeating here because it's one of those things that seems like a minor style choice until you've been burned by it: `:latest` is not a fixed, meaningful version — it's a mutable pointer that gets silently reassigned every time anyone pushes an image with that tag, meaning two different deployments both claiming to run "latest" can, in fact, be running completely different code, and there's no way to tell which is which after the fact just by looking at the tag. This defeats **rollback** (you can't roll back to "the previous latest" because that information is gone the moment a new push overwrites it) and **reproducibility** (you can't reliably answer "what exact code is running in this pod" from the tag alone). An immutable tag like a build ID or a short git SHA fixes both: `kubectl describe pod` or `docker inspect` on a running container tells you exactly which build produced it, which you can trace straight back to the exact commit and pipeline run that created it.

There's a third, GitOps-specific reason this matters, which doc 08 covers from ArgoCD's side but is worth stating from ACR's side too: ArgoCD only re-syncs when the **content** of the values file it's watching actually changes. If every deploy pushed an image tagged `:latest`, the corresponding line in `gitops/apps/ecommerce-dev/values.yaml` would read `tag: latest` on every single deploy — an unchanging string — and the GitOps commit that's supposed to represent "deploy this new build" would have no diff at all. ArgoCD would have nothing to notice, and the deployment simply wouldn't happen through this pipeline's mechanism. Using `$(Build.BuildId)` guarantees every real deploy produces a genuinely different value in that file, which is what actually drives the whole GitOps loop.

## How AKS pulls images with zero stored credentials

A traditional way to let a Kubernetes cluster pull from a private registry is an `imagePullSecret` — a Kubernetes Secret holding registry credentials, referenced by each pod spec, that has to be created, distributed to every namespace that needs it, and rotated manually whenever those credentials change. This project avoids that mechanism entirely, using AKS's native integration with ACR instead, and the machinery behind it is a good, concrete introduction to what a **managed identity** actually is and does.

An Azure **managed identity** is an identity Azure creates and manages on behalf of a resource — no username, no password, no secret you have to generate, store, or rotate yourself; Azure handles the underlying credential material invisibly, and other Azure resources can be granted permissions against that identity the same way they'd be granted permissions against a human user or a traditional service principal. An AKS cluster actually has *two* separate managed identities serving different purposes, and this distinction trips people up the first time they encounter it: the **cluster identity** (the control plane's own identity, used to manage other Azure resources like the load balancer and disks on the cluster's behalf) and the **kubelet identity** (used by the nodes themselves — specifically, the `kubelet` process running on every node — to pull container images and make other Azure API calls on behalf of the pods scheduled to that node). `terraform/modules/aks/main.tf` grants the second one, specifically, the ability to pull from ACR:

```hcl
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}
```

This is a **role assignment** — granting a specific, scoped Azure RBAC role (`AcrPull`, which permits pulling images but not pushing or managing the registry) to a specific identity (the kubelet identity) against a specific resource (the registry, referenced by `var.acr_id`). Once this exists, any pod spec on this cluster can simply reference `youracr.azurecr.io/ecommerce-api:123` as its image, with no `imagePullSecrets` field at all, and the node's kubelet transparently authenticates to ACR using its own managed identity to complete the pull. This is exactly what the CLI shortcut `az aks update --attach-acr` does under the hood — it's the standard, Microsoft-recommended pattern for AKS-to-ACR integration, and this project's Terraform implements it explicitly rather than relying on a one-off CLI command a future operator might forget to re-run. The comment in the module makes the resulting benefit explicit: no `docker login`, no secret to leak, nothing to rotate, ever, for this specific credential path — matching the `admin_enabled = false` choice on the registry itself (covered in doc 10 and doc 09), which shuts off the one remaining credential-based access path (a shared admin username/password) entirely, leaving identity-based access as the only way in or out.

## Vulnerability scanning: Defender for Cloud

One capability this project's Terraform doesn't provision, but that's worth knowing about as a production best practice sitting directly adjacent to everything covered above, is **Microsoft Defender for Cloud's container image scanning**. Once enabled on a registry, it automatically scans every image pushed to ACR for known vulnerabilities in the OS packages and language dependencies baked into its layers, surfacing findings (with severity ratings) before those images ever get pulled into a running cluster. This closes a gap that ACR's own access controls don't address at all — a private, identity-gated registry is still perfectly capable of storing and serving an image with a known-critical vulnerability in one of its base layers; access control and vulnerability scanning are two independent, complementary concerns. In a fuller production build-out of this project, enabling Defender for Cloud on the registry and wiring its findings into a pipeline gate (failing a deploy, or at least requiring an acknowledgment, if a newly pushed image has critical unpatched vulnerabilities) would be a natural next step layered on top of everything this doc and doc 13 already cover.

## Key terms

- **Container registry** — a service for storing and distributing container images, analogous to a package repository but for Docker/OCI images.
- **Private registry** — a registry under your own access control, as opposed to a public registry like Docker Hub where images are broadly pullable by default.
- **SKU (Stock Keeping Unit)** — the pricing/feature tier of an Azure resource; ACR's Premium tier specifically is required to use Private Endpoints and geo-replication.
- **Geo-replication** — an ACR Premium feature that keeps a registry synchronized across multiple Azure regions for lower-latency, more resilient pulls.
- **Immutable tag** — an image tag (like a build ID or git SHA) that always refers to exactly one, unchanging image, as opposed to a mutable tag like `latest` that can be silently reassigned.
- **Managed identity** — an Azure-managed identity for a resource, with no credential material a human ever has to generate, store, or rotate.
- **Kubelet identity** — the specific managed identity AKS nodes use to pull images and make Azure API calls on behalf of scheduled pods, distinct from the cluster's own control-plane identity.
- **Role assignment (RBAC)** — granting a specific, scoped permission (a role, e.g. `AcrPull`) to a specific identity against a specific resource.
- **`imagePullSecrets`** — the traditional Kubernetes mechanism for supplying registry credentials to a pod spec; unnecessary here because managed identity plus `AcrPull` replaces it entirely.
- **Vulnerability scanning** — automated inspection of an image's layers for known-vulnerable OS packages or dependencies, typically run on push (e.g. via Microsoft Defender for Cloud).
