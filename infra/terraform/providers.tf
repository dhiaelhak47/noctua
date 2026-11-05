terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }

  # Uncomment for AKS demo runs — stores state in Azure Blob so CI can read it.
  # backend "azurerm" {
  #   resource_group_name  = "noctua-tfstate"
  #   storage_account_name = "noctuatfstate"
  #   container_name       = "tfstate"
  #   key                  = "noctua-aks.tfstate"
  # }
}

provider "azurerm" {
  features {}
  # Credentials come from OIDC via GitHub Actions (ARM_CLIENT_ID, ARM_TENANT_ID,
  # ARM_SUBSCRIPTION_ID env vars set in the workflow; no client secret stored).
  use_oidc = true
}

provider "azuread" {}
