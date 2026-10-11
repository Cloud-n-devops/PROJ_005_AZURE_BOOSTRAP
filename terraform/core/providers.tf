terraform {
  required_version = ">= 1.8.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.53"
    }
  }
}

# No auth method is hardcoded here, deliberately, so the same code works
# in two contexts without edits:
#   - CI (GitHub Actions): ARM_CLIENT_ID/ARM_TENANT_ID/ARM_SUBSCRIPTION_ID
#     + ARM_USE_OIDC=true are set as workflow env vars (see
#     .github/workflows/terraform.yml) -> OIDC federated credential auth,
#     no client secret, ever.
#   - Local (your machine, e.g. for `teardown.sh`): run `az login` first
#     and leave ARM_* unset -> the provider falls back to your Azure CLI
#     session automatically. No secrets stored locally either way.
provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}

provider "azuread" {
}
