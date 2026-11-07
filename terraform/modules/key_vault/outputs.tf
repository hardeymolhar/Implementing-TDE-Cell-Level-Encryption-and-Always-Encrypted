output "id" {
  description = "Key Vault resource ID."
  value       = azurerm_key_vault.kv.id

  # Anything using this ID, such as a secret written by another module, waits
  # until the deployer can actually write to the vault.
  depends_on = [azurerm_key_vault_access_policy.deployer]
}

output "name" {
  description = "Key Vault name."
  value       = azurerm_key_vault.kv.name
}

output "tde_key_id" {
  description = "ID of the TDE protector key."
  value       = azurerm_key_vault_key.tde.id
}

output "ae_cmk_id" {
  description = "ID of the Always Encrypted column master key."
  value       = azurerm_key_vault_key.ae_cmk.id
}

output "sql_admin_password" {
  description = "SQL admin password, read back from the vault."
  value       = data.azurerm_key_vault_secret.sql_admin_password.value
  sensitive   = true
}

output "sql_admin_password_secret_id" {
  description = "Versionless ID of the SQL admin password secret."
  value       = azurerm_key_vault_secret.sql_admin_password.versionless_id
}

output "dmk_password_secret_id" {
  description = "Versionless ID of the database master key password secret."
  value       = azurerm_key_vault_secret.dmk_password.versionless_id
}

output "certificate_thumbprint" {
  description = "Thumbprint of the CLE certificate."
  value       = azurerm_key_vault_certificate.sql_lab.thumbprint
}
