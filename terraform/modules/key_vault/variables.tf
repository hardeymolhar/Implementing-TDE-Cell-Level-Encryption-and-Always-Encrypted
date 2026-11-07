variable "name" {
  description = "Key Vault name (3-24 chars, globally unique)."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to deploy into."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "tenant_id" {
  description = "Entra tenant ID for the vault and its access policies."
  type        = string
}

variable "deployer_object_id" {
  description = "Object ID of the identity running Terraform."
  type        = string
}

variable "tags" {
  description = "Tags applied to the vault."
  type        = map(string)
  default     = {}
}
