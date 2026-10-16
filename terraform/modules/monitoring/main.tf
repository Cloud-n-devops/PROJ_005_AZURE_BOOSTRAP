locals {
  tags = {
    environment = var.environment
    managed_by  = "terraform"
    owner       = var.owner_tag
  }
}

resource "azurerm_resource_group" "monitoring" {
  name     = "rg-monitoring-baseline"
  location = var.location
  tags     = local.tags
}

resource "azurerm_log_analytics_workspace" "core" {
  name                = "law-baseline-${var.environment}"
  resource_group_name = azurerm_resource_group.monitoring.name
  location            = azurerm_resource_group.monitoring.location
  sku                 = "PerGB2018"
  retention_in_days   = 30 # stays inside the 31-day no-charge retention window

  # Hard ingestion cap: once this workspace ingests daily_quota_gb in a
  # day, Azure stops accepting further data until 00:00 UTC. This is a
  # zero-cost safety net against a future diagnostic setting (e.g. AKS
  # Container Insights) silently blowing past the ~5 GB/month free
  # Analytics Logs allowance. Activity Log/platform metrics ingestion
  # itself is always free and unmetered, so this cap doesn't affect it —
  # it only protects you if something else starts sending high-volume logs.
  daily_quota_gb = var.log_analytics_daily_quota_gb

  tags = local.tags
}

# Subscription Activity Log -> Log Analytics. This is close to a
# "must-have" — without it you have no audit trail of who did what at
# the subscription/RBAC level.
resource "azurerm_monitor_diagnostic_setting" "activity_log" {
  name                       = "activity-log-to-law"
  target_resource_id         = "/subscriptions/${data.azurerm_subscription.current.subscription_id}"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.core.id

  enabled_log {
    category = "Administrative"
  }
  enabled_log {
    category = "Security"
  }
  enabled_log {
    category = "Policy"
  }
  enabled_log {
    category = "Alert"
  }
}

data "azurerm_subscription" "current" {}

# Action group used by the budget alert (and available for other alert rules)
resource "azurerm_monitor_action_group" "core" {
  name                = "ag-core-alerts"
  resource_group_name = azurerm_resource_group.monitoring.name
  short_name          = "coreops"
  tags                = local.tags

  dynamic "email_receiver" {
    for_each = var.alert_emails
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

# Microsoft Defender for Cloud — Free tier is on by default; this enables
# the paid "Defender" plan for the resource types most subscriptions want
# covered from day one. Adjust/remove plans you don't need (cost impact).
resource "azurerm_security_center_subscription_pricing" "defender_servers" {
  count         = var.enable_defender ? 1 : 0
  tier          = "Free"
  resource_type = "VirtualMachines"
}

resource "azurerm_security_center_subscription_pricing" "defender_storage" {
  count         = var.enable_defender ? 1 : 0
  tier          = "Free"
  resource_type = "StorageAccounts"
}

# Security contact so Defender findings actually reach someone
resource "azurerm_security_center_contact" "core" {
  count               = length(var.alert_emails) > 0 ? 1 : 0
  name                = "default"
  email               = var.alert_emails[0]
  alert_notifications = true
  alerts_to_admins    = true
}
