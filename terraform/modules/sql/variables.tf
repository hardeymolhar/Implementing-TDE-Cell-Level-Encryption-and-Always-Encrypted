variable "server_name" {
  description = "SQL logical server name (globally unique)."
  type        = string
}

variable "database_name" {
  description = "Database name."
  type        = string
  default     = "cle-database"
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
  description = "Entra tenant ID of the SQL Entra admin."
  type        = string
}

variable "entra_admin_login" {
  description = "Display name or UPN of the Entra admin."
  type        = string
}

variable "entra_admin_id" {
  description = "Object ID of the Entra admin."
  type        = string
}

variable "sql_admin_login" {
  description = "SQL authentication admin login."
  type        = string
}

variable "sql_admin_password" {
  description = "SQL authentication admin password."
  type        = string
  sensitive   = true
}

variable "key_vault_id" {
  description = "Key Vault that holds the TDE protector."
  type        = string
}

variable "tde_key_id" {
  description = "ID of the Key Vault key used as the TDE protector."
  type        = string
}

variable "client_ip" {
  description = "Public IP allowed through the server firewall."
  type        = string
}

variable "audit_blob_endpoint" {
  description = "Blob endpoint of the storage account that receives audit logs."
  type        = string
}

variable "audit_storage_key" {
  description = "Access key of the storage account that receives audit logs."
  type        = string
  sensitive   = true
}

variable "log_retention_days" {
  description = "Days to keep audit logs."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Tags applied to the server and database."
  type        = map(string)
  default     = {}
}
