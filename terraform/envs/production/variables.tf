variable "subscription_id" {
  type = string
}

variable "budget_amount" {
  description = "Monthly budget in USD scoped to this environment's resource group only"
  type        = number
  default     = 1
}

variable "budget_alert_emails" {
  type = list(string)
}
