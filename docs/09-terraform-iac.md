# 09 — Terraform and Infrastructure as Code

## Why Infrastructure as Code exists

Everything up to this point in the project — the Dockerfiles, the Kubernetes manifests, the Helm chart — describes *what runs*. Terraform, in `terraform/`, describes *what the runs run on*: the resource group, the virtual network, the AKS cluster itself, the container registry, the Application Gateway. Before Infrastructure as Code was common practice, this layer was usually built by a person clicking through the Azure Portal, or running one-off `az` CLI commands from memory or a wiki page. That approach has a specific, recurring set of failure modes worth naming, because they're exactly what IaC is designed to eliminate. First, it isn't **repeatable** — recreating an identical dev environment for a second team, or rebuilding prod after a regional disaster, means someone remembering (or re-discovering) every setting they clicked through the first time, and getting it slightly wrong is the default outcome, not the exception. Second, infrastructure changes made through a portal leave no **code review** trail — nobody sees "this NSG rule opened port 22 to the internet" before it happens, the way a pull request would surface it. Third, there's no mechanism to detect **drift** — infrastructure quietly diverging from what it's supposed to be, because someone changed a setting by hand outside of whatever process was meant to govern it (this is the same problem GitOps/ArgoCD solves for Kubernetes resources in doc 08, one layer up the stack). Fourth, disaster recovery becomes a manual, stressful, error-prone exercise instead of "run the same code again."

Terraform (a specific, HashiCorp-authored tool for IaC — not the only one, but the one this project uses) solves this by letting you describe infrastructure *declaratively*, in files, that live in the same Git repo as everything else, subject to the same pull-request review every other change goes through. You describe the end state you want; Terraform figures out what API calls are needed to get the real world to match it.

## Core Terraform concepts, using this project's actual code

A **provider** is a plugin that teaches Terraform how to talk to a specific API — in this project, `hashicorp/azurerm`, the provider for Azure Resource Manager. Every environment's `providers.tf` declares it:

```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
```

A **resource** is a single infrastructure object Terraform will create, update, or destroy on your behalf — `azurerm_virtual_network`, `azurerm_kubernetes_cluster`, `azurerm_container_registry`, and so on, each one a block in this project's `.tf` files. A **data source** (not heavily used in this project, but worth knowing) is the read-only counterpart — a way to look up information about a resource that already exists but that this Terraform configuration didn't create, without taking ownership of managing it.

The **plan/apply lifecycle** is Terraform's core workflow, and it exists specifically to avoid ever surprising you with what a command is about to do. `terraform init` downloads the providers a configuration needs and sets up its working directory. `terraform plan` is a **dry run**: Terraform compares your `.tf` files against its recorded state (see below) and against the real infrastructure, and prints exactly what it would create, change, or destroy — without actually doing any of it. `terraform apply` re-runs that same comparison and then, after you confirm, actually executes the API calls. The discipline of always running `plan` before `apply` (and reading its output) is the single most important safety habit in Terraform — it's your last chance to notice "wait, this is about to destroy and recreate my production database" before it happens.

## State: what it is, and why it's dangerous to lose or hand-edit

Terraform needs to remember, between runs, which real-world resources correspond to which blocks in your `.tf` files — this record is the **state file** (`terraform.tfstate`, JSON, created automatically the first time you `apply`). Without it, Terraform would have no way to know that the `azurerm_virtual_network.this` block in your code is *this specific* VNet in Azure rather than a brand-new one it should create, and every `plan` would either try to recreate everything from scratch or fail to reconcile at all. This makes the state file simultaneously essential and dangerous: losing it means Terraform loses track of everything it manages (you'd have to painstakingly `terraform import` every resource back in one at a time, or delete and recreate it all), and hand-editing it — even to fix something that looks obviously wrong — routinely corrupts the relationships Terraform relies on internally, causing the *next* `plan` or `apply` to do something destructive and unexpected.

This project's environments deliberately leave **remote state** commented out, and the comment in `terraform/environments/dev/providers.tf` is worth reading in full because it explains exactly why a real team can't skip this step:

```hcl
# Why this matters in a real team setting:
#   - Local state (the default - a terraform.tfstate file on your own disk)
#     cannot be safely shared. Two people running `terraform apply` from
#     their own laptops against the same environment will each have a
#     different view of "reality" and will eventually overwrite each
#     other's changes or apply against stale state.
#   - An `azurerm` backend stores state in a Storage Account blob instead,
#     so everyone (and every CI/CD pipeline) reads/writes the same state.
#   - The backend also provides STATE LOCKING (via a blob lease): while one
#     `apply` is in progress, a second concurrent `apply` is blocked
#     instead of racing and corrupting state.
#   - Remote state can also be encrypted at rest and access-controlled via
#     Azure RBAC, which a file sitting on a laptop cannot be.

# backend "azurerm" {
#   resource_group_name  = "rg-tfstate"
#   storage_account_name = "sttfstateecomdev"
#   container_name       = "tfstate"
#   key                  = "dev.terraform.tfstate"
# }
```

**Locking** is worth dwelling on specifically because the failure mode it prevents is subtle: without it, two people (or a person and a CI pipeline) running `apply` at the same moment both read the same starting state, both compute their own plan against it, and both write their own version back when they finish — the second write silently clobbers whatever the first `apply` actually did, and Terraform's own state now disagrees with reality in a way that's hard to detect until something breaks later. A remote backend acquires a lease (lock) on the state blob for the duration of an `apply`, so the second run simply waits or fails loudly instead of racing. To actually use this, you'd provision the storage account and container once (commonly via a small, separate, one-time-applied Terraform config, precisely because you can't store *that* storage account's own state inside itself), uncomment the block, fill in your values, and re-run `terraform init` — Terraform will offer to migrate your existing local state into the new backend automatically.

## Modules: why this project is split into networking / acr / aks / appgw-waf

A Terraform **module** is a reusable, self-contained group of resources with its own input variables and output values — conceptually similar to a function in a programming language. `terraform/modules/` in this project has four: `networking`, `acr`, `aks`, and `appgw-waf`. Splitting infrastructure into modules along these lines buys two things. The first is **reusability**: both `terraform/environments/dev` and `terraform/environments/prod` call the exact same four modules with different input values, rather than duplicating the resource definitions twice and letting them drift apart over time (the pattern is deliberately parallel to how `helm/ecommerce-chart` is one set of templates consumed with `values-dev.yaml` vs. `values-prod.yaml` — same shape, different inputs, see doc 07). The second is **blast-radius isolation**: each module owns a coherent slice of concerns (the network, the registry, the cluster, the internet-facing edge) with a clean interface between them, so a change to how the AKS module configures node pools can't accidentally also touch NSG rules — you'd have to explicitly wire a new value across the module boundary via variables/outputs for that to happen, which forces the dependency to be visible and deliberate rather than accidental.

**Variables** are a module's inputs (declared in each module's `variables.tf`), and **outputs** are its return values (declared in `outputs.tf`) that other modules or the root configuration can consume. This project's dependency chain flows through outputs cleanly: the `networking` module's `outputs.tf` exposes `subnet_ids` (a map), `acr_private_dns_zone_id`, `resource_group_name`, and `location`; the environment root module (`terraform/environments/dev/main.tf`) then feeds those straight into the other three modules:

```hcl
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
  ...
  aks_subnet_id = module.networking.subnet_ids["aks"]
  acr_id        = module.acr.acr_id
  ...
}
```

Notice `module.acr.acr_id` feeding into the `aks` module: Terraform automatically figures out from this reference that `aks` depends on `acr`, and builds the registry before granting the cluster's kubelet identity `AcrPull` against it (that role assignment is covered fully in doc 11) — you never have to declare ordering explicitly; it falls out of which outputs feed which variables.

## Reading dev vs. prod: same modules, different inputs

`terraform/environments/dev/main.tf` and `terraform/environments/prod/main.tf` call the identical four modules in the identical order — the only differences live in the values passed in, exactly mirroring the values-dev/values-prod relationship from doc 07. A few concrete, deliberate differences, comparing `terraform/environments/dev/terraform.tfvars.example` against `terraform/environments/prod/terraform.tfvars.example`:

```hcl
# dev
aks_kubernetes_version      = null   # let Azure pick its current default
aks_private_cluster_enabled = false  # reachable with kubectl straight from a laptop
aks_system_node_pool = { vm_size = "Standard_D2s_v5", min_count = 1, max_count = 2 }
aks_user_node_pool   = { vm_size = "Standard_D2s_v5", min_count = 1, max_count = 3 }
appgw_waf_mode = "Detection"
appgw_sku_capacity = { min = 1, max = 2 }

# prod
aks_kubernetes_version      = "1.29"  # pinned explicitly, upgraded deliberately
aks_private_cluster_enabled = true    # control plane never internet-reachable
aks_system_node_pool = { vm_size = "Standard_D4s_v5", min_count = 3, max_count = 5 }
aks_user_node_pool   = { vm_size = "Standard_D4s_v5", min_count = 3, max_count = 10 }
appgw_waf_mode = "Prevention"
appgw_sku_capacity = { min = 2, max = 10 }
```

Every one of these differences is explained in more depth in its relevant doc (AKS sizing/private clusters in doc 12, WAF mode in doc 10) — the point to internalize here is structural: nothing about the *modules themselves* changes between environments, only the tfvars fed into them, which is precisely the discipline that keeps dev and prod from silently drifting into two different, undocumented architectures over time. The root module's own comment on the `aks` block even calls out one such deliberate difference directly — `sku_tier = "Free"` hardcoded in dev's `main.tf` versus `sku_tier = "Standard"` hardcoded in prod's — because that specific setting (an uptime SLA for the control plane) is judged not worth exposing as a variable at all; it's simply always right for its environment.

## Walking each module's key resources

**`modules/networking`** builds the VNet, three subnets, one NSG per subnet, a NAT Gateway, and the private DNS zone ACR will register into — all covered in full detail, with the actual security-rule reasoning, in doc 10. The one Terraform-specific detail worth calling out here is the resource group itself: `azurerm_resource_group.this` is created inside this module (not in the root environment config), named `rg-${var.project}-${var.environment}`, and every other module receives its ID/name as an input rather than creating its own — keeping exactly one resource group per environment, with a single, predictable owner for its lifecycle.

**`modules/acr`** provisions the Azure Container Registry at `Premium` SKU (enforced by a `validation` block that fails `terraform plan` outright if you try to pass anything else — Premium is a hard requirement for Private Endpoints, covered in doc 11) plus the private endpoint and DNS zone group wiring that lets AKS resolve and reach it privately (covered in doc 10). `admin_enabled = false` and `public_network_access_enabled = false` are both explicit, commented choices: no shared admin password exists at all, and the registry is reachable only from inside the VNet.

**`modules/aks`** provisions the cluster itself: a system-assigned managed identity for the control plane, a `default_node_pool` restricted to critical add-ons only (`only_critical_addons_enabled = true`), a separate `azurerm_kubernetes_cluster_node_pool.user` for application workloads, Azure CNI networking, and — the resource that ties this module to the `acr` module — an `azurerm_role_assignment` granting `AcrPull` to the cluster's kubelet identity. Doc 12 covers this module's design choices (node pool separation, private clusters, autoscaling) in full.

**`modules/appgw-waf`** provisions the internet-facing edge: a public IP, a WAF policy running the OWASP Core Rule Set, and the Application Gateway itself at the `WAF_v2` SKU with autoscaling, an HTTP listener that only exists to redirect to HTTPS, and a request routing rule forwarding real traffic to `var.backend_address` — a placeholder standing in for the AKS ingress controller's address, since this Terraform project deliberately stops at the edge of the cluster and never provisions anything with a Kubernetes/Helm provider. Doc 10 walks through the WAF and Application Gateway reasoning end to end.

## Running this for real: what this project does not do for you

This Terraform is written to run against a real Azure subscription, and it is **not** applied as part of this practice session — no cost is incurred by reading or writing these files. To actually stand up the infrastructure they describe, the sequence is: `az login` (authenticate the Azure CLI, which Terraform's `azurerm` provider reuses by default rather than requiring separate credentials); copy `terraform.tfvars.example` to `terraform.tfvars` in whichever environment directory you're targeting and fill in real values (this file is `.gitignore`d specifically so nobody accidentally commits subscription-specific or sensitive values — see `terraform/.gitignore`); `terraform init` from inside that environment directory; `terraform plan -var-file=terraform.tfvars` to review exactly what will be created; and, only after reading that plan carefully, `terraform apply -var-file=terraform.tfvars`. Doc 15's runbook walks through this sequence as one concrete, ordered phase, including the follow-up step of running `az aks get-credentials` once the cluster exists so `kubectl`/`helm`/`argocd` can reach it.

## Key terms

- **Infrastructure as Code (IaC)** — describing infrastructure declaratively in version-controlled files instead of manually configuring it through a UI or ad hoc commands.
- **Provider** — a Terraform plugin implementing the API calls needed to manage a specific platform's resources (here, `azurerm` for Azure).
- **Resource** — a single infrastructure object Terraform creates/manages, corresponding to one block in a `.tf` file.
- **Data source** — a read-only reference to an existing resource Terraform did not create itself.
- **Plan** — a dry-run preview of exactly what `apply` would create, change, or destroy, computed by diffing code against state and real infrastructure.
- **Apply** — executing the actual API calls to bring real infrastructure in line with a plan.
- **State file** — Terraform's record of which real-world resources correspond to which configuration blocks; required for every subsequent plan/apply to work correctly.
- **Remote state** — storing the state file in a shared backend (e.g. an Azure Storage Account blob) instead of on one person's disk, enabling team collaboration.
- **State locking** — a mechanism (e.g. a blob lease) preventing two concurrent `apply` runs from corrupting the same state file.
- **Module** — a reusable, self-contained group of resources with defined input variables and output values, callable from a root configuration or another module.
- **Variables / outputs** — a module's inputs and return values respectively, forming the interface other code uses to consume it without knowing its internals.
- **Drift** — a divergence between what infrastructure code declares and what actually exists, typically caused by manual out-of-band changes.
