output "resource_group_name" {
  value = azurerm_resource_group.production.name
}

output "budget_id" {
  value = module.budget.budget_id
}
