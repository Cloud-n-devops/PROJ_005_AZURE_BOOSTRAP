# Everything specific to the staging environment lives under this
# resource group. Future workload projects (e.g. an AKS module) get
# added here, reusing var.rg.name as their parent scope and
# data.terraform_remote_state.core.outputs.log_analytics_workspace_id
# for diagnostics instead of creating a second Log Analytics workspace.

resource "azurerm_resource_group" "staging" {
  name     = "rg-staging"
  location = var.location
  tags = {
    environment = "staging"
    managed_by  = "terraform"
  }
}

# Per-environment budget — tracks staging's spend independently of
# core's subscription-wide budget, so a runaway staging experiment is
# visible without digging through total subscription cost.
module "budget" {
  source             = "../../modules/budget"
  subscription_id    = var.subscription_id
  resource_group_id  = azurerm_resource_group.staging.id
  budget_amount      = var.budget_amount
  budget_name_suffix = "staging"
  alert_emails       = var.budget_alert_emails
  action_group_id    = data.terraform_remote_state.core.outputs.action_group_id
}

# ---- Workloads go below this line -----------------------------------
# e.g. module "aks" { source = "../../modules/aks" ... }
