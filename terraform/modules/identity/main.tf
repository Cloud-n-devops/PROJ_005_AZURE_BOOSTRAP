# The terraform_auth app registration + first federated credential were
# created by bootstrap/bootstrap.sh (chicken-and-egg: Terraform can't
# create the identity it authenticates as). From here on, additional
# scoped role assignments and federated credentials for terraform_auth
# are managed here, as code, so changes are reviewable via PR.

data "azuread_service_principal" "terraform_auth" {
  object_id = var.terraform_auth_object_id
}

# bootstrap.sh already created the branch- and environment-scoped
# federated credentials this repo uses (branch:staging, branch:main,
# environment:plan-preview-staging, environment:plan-preview-production)
# and granted subscription-wide Contributor. The two examples below show
# the next hardening step once the landing zone is stable: splitting
# terraform_auth's RBAC down to rg-staging/rg-production specifically
# instead of relying on the broad subscription grant, so a leaked
# staging-scoped token can't touch production resources even though both
# currently share one app registration.
#
# resource "azurerm_role_assignment" "terraform_auth_staging_scoped" {
#   scope                = "/subscriptions/${var.subscription_id}/resourceGroups/rg-staging"
#   role_definition_name = "Contributor"
#   principal_id         = data.azuread_service_principal.terraform_auth.object_id
# }
#
# resource "azurerm_role_assignment" "terraform_auth_production_scoped" {
#   scope                = "/subscriptions/${var.subscription_id}/resourceGroups/rg-production"
#   role_definition_name = "Contributor"
#   principal_id         = data.azuread_service_principal.terraform_auth.object_id
# }
#
# For real isolation (a compromised staging token cannot reach
# production at all), go further: split terraform_auth into two app
# registrations (terraform_auth_staging, terraform_auth_production),
# each with only its own branch/environment federated credentials and
# only its own resource group's RBAC — at the cost of bootstrap.sh and
# the workflow's secrets needing a second identity's ARM_CLIENT_ID.
