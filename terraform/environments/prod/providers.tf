# ---------------------------------------------------------------------------
# Provider & backend configuration - prod environment
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }

  # ---------------------------------------------------------------------------
  # Remote state (commented out on purpose for this lab)
  #
  # This matters even more for prod than dev: multiple engineers and CI/CD
  # pipelines will run `terraform plan/apply` against this environment, and
  # a corrupted or divergent local state file here could mean an accidental
  # `destroy` of production infrastructure. An azurerm backend gives you:
  #   - a single shared source of truth for state (Storage Account blob)
  #   - state locking via blob lease, so concurrent applies queue instead
  #     of racing
  #   - encryption at rest + Azure RBAC-based access control on who can
  #     even read the state file (which may contain sensitive attributes)
  #
  # Use a SEPARATE storage account/container (or at least a separate `key`)
  # from dev, so a mistake targeting the wrong workspace can't cross-
  # contaminate environments.
  # ---------------------------------------------------------------------------

  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "sttfstateecomprod"
  #   container_name       = "tfstate"
  #   key                  = "prod.terraform.tfstate"
  # }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      # In prod, prefer requiring the resource group to be empty before it
      # can be destroyed - this is a deliberate speed bump against an
      # accidental `terraform destroy` wiping out an entire environment.
      prevent_deletion_if_contains_resources = true
    }
  }
}
