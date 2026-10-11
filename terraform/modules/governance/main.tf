data "azurerm_subscription" "current" {}

# Built-in initiative: Azure Security Benchmark. This is the closest thing
# to an industry-standard "must have" policy baseline for a new
# subscription — covers identity, network, logging, data protection, etc.
data "azurerm_policy_set_definition" "security_benchmark" {
  display_name = "Microsoft cloud security benchmark"
}

resource "azurerm_subscription_policy_assignment" "security_benchmark" {
  name                 = "security-benchmark-baseline"
  policy_definition_id = data.azurerm_policy_set_definition.security_benchmark.id
  subscription_id      = data.azurerm_subscription.current.id
  location             = "eastus" # required for assignments with a managed identity
  identity {
    type = "SystemAssigned"
  }

  # Audit-only by default — flip enforcement_mode once you've reviewed
  # findings and are ready to actually block non-compliant deployments.
  enforcement_mode = "DoNotEnforce"
}

# Built-in policy: require a specific tag on all resources. Cheap,
# high-value governance — makes cost allocation and ownership queries
# possible from day one instead of retrofitted later.
data "azurerm_policy_definition_built_in" "require_tag" {
  display_name = "Require a tag on resources"
}

resource "azurerm_subscription_policy_assignment" "require_owner_tag" {
  name                 = "require-owner-tag"
  policy_definition_id = data.azurerm_policy_definition_built_in.require_tag.id
  subscription_id      = data.azurerm_subscription.current.id

  parameters = jsonencode({
    tagName = {
      value = "owner"
    }
  })
}

# Built-in policy: allowed locations. Keeps resources from being created
# in regions you don't intend to operate in (data residency, cost).
data "azurerm_policy_definition_built_in" "allowed_locations" {
  display_name = "Allowed locations"
}

resource "azurerm_subscription_policy_assignment" "allowed_locations" {
  name                 = "allowed-locations"
  policy_definition_id = data.azurerm_policy_definition_built_in.allowed_locations.id
  subscription_id      = data.azurerm_subscription.current.id

  parameters = jsonencode({
    listOfAllowedLocations = {
      value = var.allowed_locations
    }
  })
}

# Resource lock on the Terraform state resource group — protects your
# backend from accidental deletion regardless of who has Contributor.
resource "azurerm_management_lock" "tfstate_rg" {
  name       = "lock-tfstate-rg"
  scope      = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/rg-terraform-state"
  lock_level = "CanNotDelete"
  notes      = "Prevents accidental deletion of the Terraform remote state resource group."
}
