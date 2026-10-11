output "log_analytics_workspace_id" {
  value = module.monitoring.log_analytics_workspace_id
}

output "action_group_id" {
  value = module.monitoring.action_group_id
}

output "budget_id" {
  value = module.budget.budget_id
}
