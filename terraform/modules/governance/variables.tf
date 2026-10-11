variable "subscription_id" {
  type = string
}

variable "owner_tag" {
  type = string
}

variable "allowed_locations" {
  description = "Regions resources are permitted to be created in"
  type        = list(string)
  default     = ["eastus", "eastus2"]
}
