terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
  }
}

###############################################################################
# Azure SQL logical server
#   - System-assigned identity: used to reach the TDE key in Key Vault
#   - Mixed authentication: Entra admin plus a SQL admin login
###############################################################################

resource "azurerm_mssql_server" "sql" {
  name                          = var.server_name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  version                       = "12.0"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true

  # SQL authentication admin (server-level login); password comes from Key Vault
  administrator_login          = var.sql_admin_login
  administrator_login_password = var.sql_admin_password

  identity {
    type = "SystemAssigned"
  }

  azuread_administrator {
    login_username              = var.entra_admin_login
    object_id                   = var.entra_admin_id
    tenant_id                   = var.tenant_id
    azuread_authentication_only = false # allow both Entra and SQL logins
  }

  tags = var.tags

  # azurerm_mssql_server_transparent_data_encryption below owns the TDE key.
  # Azure reports that key on the server too, so without this Terraform tries to
  # clear it on every apply, and auto-rotation would also show up as drift.
  lifecycle {
    ignore_changes = [transparent_data_encryption_key_vault_key_id]
  }
}

# Vault access policy for the server's system-assigned identity:
# exactly what TDE needs to use the key - Get, WrapKey, UnwrapKey.
# No secret or certificate access: TDE only uses keys.
resource "azurerm_key_vault_access_policy" "sql" {
  key_vault_id = var.key_vault_id
  tenant_id    = azurerm_mssql_server.sql.identity[0].tenant_id
  object_id    = azurerm_mssql_server.sql.identity[0].principal_id

  key_permissions = ["Get", "WrapKey", "UnwrapKey"]
}

###############################################################################
# Customer-managed TDE: make the RSA key the server's TDE protector
###############################################################################

resource "azurerm_mssql_server_transparent_data_encryption" "tde" {
  server_id             = azurerm_mssql_server.sql.id
  key_vault_key_id      = var.tde_key_id
  auto_rotation_enabled = true # picks up new key versions automatically

  depends_on = [azurerm_key_vault_access_policy.sql]
}

###############################################################################
# Azure SQL Database - Basic tier, 2 GB
###############################################################################

resource "azurerm_mssql_database" "db" {
  name                 = var.database_name
  server_id            = azurerm_mssql_server.sql.id
  sku_name             = "Basic"
  max_size_gb          = 2 # Basic maximum
  collation            = "SQL_Latin1_General_CP1_CI_AS"
  zone_redundant       = false
  storage_account_type = "Geo" # backup redundancy; "Local" is cheaper but disables geo-restore
  tags                 = var.tags
  enclave_type         = "VBS" # secure enclave: lets Always Encrypted encrypt existing columns in place

  depends_on = [azurerm_mssql_server_transparent_data_encryption.tde]
}

###############################################################################
# Firewall rule for the public IP of the machine running Terraform
###############################################################################

resource "azurerm_mssql_firewall_rule" "client" {
  name             = "client-ip"
  server_id        = azurerm_mssql_server.sql.id
  start_ip_address = var.client_ip
  end_ip_address   = var.client_ip
}

###############################################################################
# Auditing, written to the sqldbauditlogs container in the storage account
#   - Azure sets that container name; these resources have no container option
#   - Uses the storage account key because the lab account can't create role
#     assignments. Terraform reads the key from the Key Vault secret
#     audit-storage-key. It is still in terraform.tfstate, so protect the state
#   - log_monitoring_enabled = false keeps this to storage only
#
# How server auditing reaches the database
#   - A server policy applies to every existing and new database on the server
#   - It always applies, whatever the database's own auditing setting is, so
#     turning database auditing off doesn't stop it
#
# How the two policies relate: they are independent
#   - A database policy doesn't override or change the server policy. They run
#     side by side, so cle-database is audited twice, in parallel
#   - Nothing is copied or merged between them: action groups, retention and
#     destination are set per policy. A group added to the server policy
#     doesn't appear in the database policy, and the reverse
#   - Microsoft advises server auditing only, unless a database needs a
#     different storage account, retention period or set of audited events
#
# Scope of an action group
#   - On the server policy, a group covers all databases on the server
#   - On a database policy, it covers only that database
#   - Individual actions (for example SELECT on one table) exist only on
#     database policies. They can't be set on a server policy
#   - The azurerm database resource has no argument for groups or actions, so
#     the database policy below uses Azure's default set
###############################################################################

resource "azurerm_mssql_server_extended_auditing_policy" "server" {
  server_id                  = azurerm_mssql_server.sql.id
  blob_storage_endpoint      = var.audit_blob_endpoint
  storage_account_access_key = var.audit_storage_key
  retention_in_days          = var.log_retention_days
  log_monitoring_enabled     = false

  # The first three are Microsoft's recommended set, and the portal's default.
  # The commented entries are the other groups Azure SQL Database supports.
  # Enable only what you need: extra groups can create very large audit volumes.
  audit_actions_and_groups = [
    "BATCH_COMPLETED_GROUP",                    # a batch, procedure or transaction operation finished; records its text
    "SUCCESSFUL_DATABASE_AUTHENTICATION_GROUP", # a principal logged in successfully
    "FAILED_DATABASE_AUTHENTICATION_GROUP",     # a principal tried to log in and failed

    # Statements. BATCH_COMPLETED_GROUP already records all statements, so
    # adding these can duplicate records.
    # "BATCH_STARTED_GROUP",                    # a batch, procedure or transaction operation started
    # "SCHEMA_OBJECT_ACCESS_GROUP",             # an object permission was used, such as SELECT on a table
    # "DBCC_GROUP",                             # any DBCC command was issued

    # Users, roles and passwords
    # "DATABASE_PRINCIPAL_CHANGE_GROUP",        # a user or other principal was created, altered or dropped
    # "DATABASE_ROLE_MEMBER_CHANGE_GROUP",      # a member was added to or removed from a database role
    # "DATABASE_PRINCIPAL_IMPERSONATION_GROUP", # impersonation in database scope, such as EXECUTE AS
    # "USER_CHANGE_PASSWORD_GROUP",             # a contained user's password changed through ALTER USER
    # "APPLICATION_ROLE_CHANGE_PASSWORD_GROUP", # an application role's password changed
    # "DATABASE_LOGOUT_GROUP",                  # a contained database user signed out

    # Permissions
    # "DATABASE_PERMISSION_CHANGE_GROUP",        # GRANT, REVOKE or DENY on a database-level permission
    # "DATABASE_OBJECT_PERMISSION_CHANGE_GROUP", # GRANT, REVOKE or DENY on a database object, such as a schema
    # "SCHEMA_OBJECT_PERMISSION_CHANGE_GROUP",   # GRANT, REVOKE or DENY on a schema object, such as a table

    # Ownership
    # "DATABASE_OWNERSHIP_CHANGE_GROUP",        # database owner changed through ALTER AUTHORIZATION
    # "DATABASE_OBJECT_OWNERSHIP_CHANGE_GROUP", # owner changed for an object in database scope
    # "SCHEMA_OBJECT_OWNERSHIP_CHANGE_GROUP",   # owner changed for a table, procedure or function

    # Structure and operations
    # "DATABASE_CHANGE_GROUP",        # a database was created, altered or dropped
    # "DATABASE_OBJECT_CHANGE_GROUP", # CREATE, ALTER or DROP on a database object; can be high volume
    # "SCHEMA_OBJECT_CHANGE_GROUP",   # CREATE, ALTER or DROP on a schema or schema object
    # "DATABASE_OPERATION_GROUP",     # database operations, such as a checkpoint
    # "BACKUP_RESTORE_GROUP",         # a backup or restore command was issued
    # "LEDGER_OPERATION_GROUP",       # ledger operations, such as generating or verifying a digest
  ]
}

resource "azurerm_mssql_database_extended_auditing_policy" "db" {
  database_id                = azurerm_mssql_database.db.id
  blob_storage_endpoint      = var.audit_blob_endpoint
  storage_account_access_key = var.audit_storage_key
  retention_in_days          = var.log_retention_days
  log_monitoring_enabled     = false
}
