# ---------------------------------------------------------------------------
# Provider & backend configuration - dev environment
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
  #
  # To use this for real, create a Storage Account + container up front
  # (a common bootstrap pattern is a small, separate "tfstate" Terraform
  # config applied once by hand), uncomment the block below, fill in your
  # own values, and run `terraform init` again - Terraform will offer to
  # migrate your local state into the backend automatically.
  # ---------------------------------------------------------------------------

  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "sttfstateecomdev"
  #   container_name       = "tfstate"
  #   key                  = "dev.terraform.tfstate"
  # }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      # Allow destroying a resource group that still contains resources.
      # Convenient for a learning environment where you frequently tear
      # everything down; consider setting this to false in prod so an
      # accidental `terraform destroy` on the resource group is blocked
      # unless it is actually empty.
      prevent_deletion_if_contains_resources = false
    }
  }
}
