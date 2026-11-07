variable "subscription_id" {
  description = "Azure subscription ID to deploy into."
  type        = string
  default     = "c1860220-c0d0-4d05-828b-2031e25b09a5"
}

variable "resource_group_name" {
  description = "Existing resource group to deploy into. Resources use its region."
  type        = string
  default     = "rg_sb_westus_308450_2_17940512939"
}

variable "prefix" {
  description = "Short lowercase prefix for resource names (letters and numbers, max 8)."
  type        = string
  default     = "dp300"
}

variable "entra_admin_login" {
  description = "Display name or UPN of the Entra ID admin for the SQL server (the identity running Terraform)."
  type        = string
  default     = "labuser_308450_1794051289273@instructorwhizlabs.onmicrosoft.com"
}

variable "sql_admin_login" {
  description = "SQL authentication admin login. Can't be admin, sa, root, administrator, guest or public."
  type        = string
  default     = "sqladminuser"
}

variable "log_retention_days" {
  description = "Days to keep SQL audit logs and Key Vault audit logs in the storage account."
  type        = number
  default     = 90
}
