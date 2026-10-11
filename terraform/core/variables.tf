variable "subscription_id" {
  description = "Target Azure subscription ID"
  type        = string
}

variable "location" {
  description = "Primary Azure region for baseline resources (e.g. Log Analytics workspace)"
  type        = string
  default     = "eastus"
}

variable "environment" {
  description = "Environment tag applied to all managed resources"
  type        = string
  default     = "shared"
}

variable "budget_amount" {
  description = "Monthly subscription budget in USD. Kept tiny for a $0-target learning subscription so alerts fire on the first stray charge instead of after real money accumulates."
  type        = number
  default     = 1
}

variable "budget_alert_emails" {
  description = "Email addresses notified when budget thresholds are crossed"
  type        = list(string)
}

variable "terraform_auth_object_id" {
  description = "Object ID of the terraform_auth service principal (output from bootstrap.sh)"
  type        = string
}

variable "owner_tag" {
  description = "Default 'owner' tag value applied via governance policy"
  type        = string
  default     = "kevoh"
}
