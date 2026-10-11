# This module creates EITHER a subscription-scoped budget (used once, by
# core/ — tracks total subscription spend) OR a resource-group-scoped
# budget (used per environment, by envs/staging and envs/production —
# tracks that environment's spend specifically). Pass resource_group_id
# to get the latter; leave it null (the default) for the former. Only
# one of the two resources below is ever created, controlled by count.

# Subscription-level budget — one per subscription, deployed from core/.
resource "azurerm_consumption_budget_subscription" "core" {
  count           = var.resource_group_id == null ? 1 : 0
  name            = "budget-monthly-${var.budget_name_suffix}"
  subscription_id = "/subscriptions/${var.subscription_id}"

  amount     = var.budget_amount
  time_grain = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
  }

  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.alert_emails
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.alert_emails
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = var.alert_emails
  }

  lifecycle {
    ignore_changes = [time_period[0].start_date]
  }
}

# Resource-group-scoped budget — one per environment, deployed from
# envs/staging and envs/production, so each environment's spend is
# visible and alerted on independently instead of only as one lump
# subscription total.
resource "azurerm_consumption_budget_resource_group" "env" {
  count               = var.resource_group_id != null ? 1 : 0
  name                = "budget-monthly-${var.budget_name_suffix}"
  resource_group_id   = var.resource_group_id

  amount     = var.budget_amount
  time_grain = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
  }

  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.alert_emails
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.alert_emails
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = var.alert_emails
  }

  lifecycle {
    ignore_changes = [time_period[0].start_date]
  }
}
