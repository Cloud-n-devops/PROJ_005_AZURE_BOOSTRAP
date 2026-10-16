output "log_analytics_workspace_id" {
  value = module.monitoring.log_analytics_workspace_id
}

output "action_group_id" {
  value = module.monitoring.action_group_id
}

output "budget_id" {
  value = module.budget.budget_id
}

# Single source of truth for the region: envs/* read this instead of
# defining their own default.
output "location" {
  value = var.location
}
