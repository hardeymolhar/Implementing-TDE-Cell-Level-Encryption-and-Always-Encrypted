variable "name" {
  description = "Shared name (prefix and suffix) used to build the storage account name."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to deploy into."
  type        = string
}

variable "location" {
  description = "Azure region. Must match the Key Vault's region."
  type        = string
}

variable "key_vault_id" {
  description = "Key Vault to send audit logs from, and to store the storage key in."
  type        = string
}

variable "log_retention_days" {
  description = "Days to keep audit logs."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Tags applied to the storage account."
  type        = map(string)
  default     = {}
}
