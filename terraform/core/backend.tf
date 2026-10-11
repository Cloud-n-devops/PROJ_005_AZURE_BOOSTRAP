terraform {
  backend "azurerm" {
    resource_group_name = "rg-terraform-state"
    storage_account_name = "sttfstate29339" # fill  in with $TFSTATE_SA_NAME from bootstrap.sh output
    container_name        = "tfstate"
    key                    = "core.tfstate"
  }
}
