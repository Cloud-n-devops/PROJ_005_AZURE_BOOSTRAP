module "monitoring" {
  source          = "../modules/monitoring"
  location        = var.location
  environment     = var.environment
  alert_emails    = var.budget_alert_emails
  enable_defender = true
}

module "budget" {
  source              = "../modules/budget"
  subscription_id     = var.subscription_id
  budget_amount       = var.budget_amount
  budget_name_suffix  = "core"
  alert_emails        = var.budget_alert_emails
  action_group_id     = module.monitoring.action_group_id
}

module "governance" {
  source                    = "../modules/governance"
  subscription_id           = var.subscription_id
  owner_tag                 = var.owner_tag
}

module "identity" {
  source                       = "../modules/identity"
  terraform_auth_object_id     = var.terraform_auth_object_id
  subscription_id              = var.subscription_id
}
