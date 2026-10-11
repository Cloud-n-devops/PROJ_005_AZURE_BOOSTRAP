variable "subscription_id" {
  type = string
}

variable "budget_amount" {
  type = number
}

variable "alert_emails" {
  type = list(string)
}

variable "action_group_id" {
  description = "Reserved for future use if you wire budget alerts into Azure Monitor alert rules instead of/alongside email"
  type        = string
  default     = null
}

variable "resource_group_id" {
  description = "If set, creates a resource-group-scoped budget instead of a subscription-scoped one (used by envs/staging and envs/production)"
  type        = string
  default     = null
}

variable "budget_name_suffix" {
  description = "Distinguishes budgets when more than one exists (e.g. 'core', 'staging', 'production')"
  type        = string
  default     = "core"
}
