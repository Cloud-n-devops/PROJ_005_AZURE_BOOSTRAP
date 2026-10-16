variable "subscription_id" {
  type = string
}

variable "owner_tag" {
  type = string
}

variable "location" {
  description = "Region used for the policy assignment's managed identity"
  type        = string
}

variable "allowed_locations" {
  description = "Regions resources are permitted to be created in"
  type        = list(string)
}
