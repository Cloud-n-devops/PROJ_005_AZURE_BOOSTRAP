variable "location" {
  type = string
}

variable "environment" {
  type = string
}

variable "alert_emails" {
  description = "Emails for the core action group and Defender security contact"
  type        = list(string)
  default     = []
}

variable "enable_defender" {
  type    = bool
  default = true
}

variable "log_analytics_daily_quota_gb" {
  description = "Hard daily ingestion cap on the Log Analytics workspace, in GB. Ingestion stops once hit for the rest of the day. Set low for a $0-budget learning subscription."
  type        = number
  default     = 0.2 # well under the ~5GB/month free Analytics Logs allowance even at daily cadence
}
