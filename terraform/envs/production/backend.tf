terraform {
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "sttfstate29339" # same storage account as core — fill in from bootstrap.sh output
    container_name       = "tfstate"
    key                  = "production.tfstate" # distinct blob — isolated from core.tfstate and staging.tfstate
    use_azuread_auth     = true
  }
}
