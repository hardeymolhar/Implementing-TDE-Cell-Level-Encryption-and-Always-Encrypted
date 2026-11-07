output "resource_group" {
  value = data.azurerm_resource_group.rg.name
}

output "location" {
  value = local.location
}

output "sql_server_fqdn" {
  value = module.sql.fqdn
}

output "database_name" {
  value = module.sql.database_name
}

output "sql_admin_login" {
  value = module.sql.admin_login
}

# Read the password with:
#   az keyvault secret show --vault-name <key_vault_name> --name sql-admin-password --query value -o tsv
output "sql_admin_password_secret_id" {
  value = module.key_vault.sql_admin_password_secret_id
}

output "key_vault_name" {
  value = module.key_vault.name
}

output "tde_protector_key_id" {
  value = module.key_vault.tde_key_id
}

output "always_encrypted_cmk_id" {
  value = module.key_vault.ae_cmk_id
}

output "dmk_password_secret_id" {
  value = module.key_vault.dmk_password_secret_id
}

output "certificate_thumbprint" {
  value = module.key_vault.certificate_thumbprint
}

output "client_ip" {
  value = local.client_ip
}

output "sql_server_identity_principal_id" {
  value = module.sql.server_principal_id
}

output "audit_storage_account_name" {
  value = module.monitoring.storage_account_name
}
