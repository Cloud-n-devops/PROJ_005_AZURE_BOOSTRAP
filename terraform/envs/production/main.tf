# Mirrors envs/staging/main.tf structurally — the whole point of this
# pattern is that the SAME module code gets promoted from staging to
# production via the staging -> main PR; only this file's variable
# values (via terraform.tfvars, not committed) and the backend's state
# key differ between the two environments.

resource "azurerm_resource_group" "production" {
  name     = "rg-production"
  location = data.terraform_remote_state.core.outputs.location
  tags = {
    environment = "production"
    managed_by  = "terraform"
  }
}

module "budget" {
  source             = "../../modules/budget"
  subscription_id    = var.subscription_id
  resource_group_id  = azurerm_resource_group.production.id
  budget_amount      = var.budget_amount
  budget_name_suffix = "production"
  alert_emails       = var.budget_alert_emails
  action_group_id    = data.terraform_remote_state.core.outputs.action_group_id
}

# ---- Workloads go below this line -----------------------------------
# e.g. module "aks" { source = "../../modules/aks" ... }
