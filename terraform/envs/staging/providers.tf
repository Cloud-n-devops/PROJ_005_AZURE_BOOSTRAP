terraform {
  required_version = ">= 1.8.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

# Auth: CI sets ARM_USE_OIDC=true + ARM_CLIENT_ID/TENANT/SUBSCRIPTION as
# env vars; locally, `az login` first and leave ARM_* unset to fall back
# to your Azure CLI session (used by teardown.sh / bring-up.sh).
provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}

# Reads core/'s state so this environment can reuse the shared Log
# Analytics workspace and action group instead of creating its own.
# terraform_auth needs read access to core.tfstate for this to work,
# which it already has via its Storage Blob Data Contributor grant on
# the whole tfstate container from bootstrap.sh.
data "terraform_remote_state" "core" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "sttfstate29339" # same value as backend.tf above
    container_name       = "tfstate"
    key                  = "core.tfstate"
    use_azuread_auth     = true
  }
}
