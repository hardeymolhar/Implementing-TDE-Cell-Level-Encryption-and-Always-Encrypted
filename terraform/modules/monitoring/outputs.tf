output "storage_account_name" {
  description = "Storage account holding the audit logs."
  value       = azurerm_storage_account.audit.name
}

output "storage_account_id" {
  description = "Resource ID of the audit storage account."
  value       = azurerm_storage_account.audit.id
}

output "blob_endpoint" {
  description = "Blob endpoint that audit logs are written to."
  value       = azurerm_storage_account.audit.primary_blob_endpoint
}

output "audit_storage_key" {
  description = "Storage key used by SQL auditing, read back from Key Vault."
  value       = data.azurerm_key_vault_secret.storage_key.value
  sensitive   = true
}
