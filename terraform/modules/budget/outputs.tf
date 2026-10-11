output "budget_id" {
  value = var.resource_group_id == null ? azurerm_consumption_budget_subscription.core[0].id : azurerm_consumption_budget_resource_group.env[0].id
}
