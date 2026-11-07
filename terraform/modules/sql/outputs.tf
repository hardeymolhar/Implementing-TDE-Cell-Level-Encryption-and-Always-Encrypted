output "server_id" {
  description = "SQL logical server resource ID."
  value       = azurerm_mssql_server.sql.id
}

output "server_principal_id" {
  description = "Object ID of the server's system-assigned identity."
  value       = azurerm_mssql_server.sql.identity[0].principal_id
}

output "fqdn" {
  description = "Server fully qualified domain name."
  value       = azurerm_mssql_server.sql.fully_qualified_domain_name
}

output "admin_login" {
  description = "SQL authentication admin login."
  value       = azurerm_mssql_server.sql.administrator_login
}

output "database_name" {
  description = "Database name."
  value       = azurerm_mssql_database.db.name
}
