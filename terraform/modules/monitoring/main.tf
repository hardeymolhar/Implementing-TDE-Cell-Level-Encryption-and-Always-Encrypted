terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
  }
}

###############################################################################
# Storage account for audit logs
#   - Standard tier: premium accounts aren't supported as a diagnostic destination
#   - Same region as the vault: required for diagnostic settings
#   - Azure creates and names the containers; the names can't be changed:
#       insights-logs-auditevent  Key Vault audit logs
#       sqldbauditlogs            SQL server and database audit logs
###############################################################################

resource "azurerm_storage_account" "audit" {
  name                            = lower(replace("st${var.name}audit", "-", "")) # 3-24 chars, globally unique
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  tags                            = var.tags
}

###############################################################################
# Storage account key stored as a Key Vault secret
#   1. the storage account generates the key
#   2. azurerm_key_vault_secret stores it in the vault
#   3. the data source reads it back, and consumers take it from there
#      (via the audit_storage_key output)
#   Terraform does the reading at deploy time. Azure SQL keeps its own copy of
#   the key after that, so it doesn't call the vault while writing audit logs.
###############################################################################

resource "azurerm_key_vault_secret" "storage_key" {
  name         = "audit-storage-key"
  key_vault_id = var.key_vault_id
  value        = azurerm_storage_account.audit.primary_access_key
  content_type = "storage-account-key"
}

data "azurerm_key_vault_secret" "storage_key" {
  name         = azurerm_key_vault_secret.storage_key.name
  key_vault_id = var.key_vault_id
}

###############################################################################
# Key Vault diagnostics
#   AuditEvent records every authenticated request, including the KeyWrap and
#   KeyUnwrap calls TDE makes.
###############################################################################

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name               = "kv-audit-to-storage"
  target_resource_id = var.key_vault_id
  storage_account_id = azurerm_storage_account.audit.id

  enabled_log {
    category = "AuditEvent"
  }
}

###############################################################################
# Log retention for Key Vault logs
#   Diagnostic settings have no retention of their own, so a lifecycle rule
#   deletes old blobs. SQL audit logs use retention_in_days in the SQL module.
###############################################################################

resource "azurerm_storage_management_policy" "audit" {
  storage_account_id = azurerm_storage_account.audit.id

  rule {
    name    = "delete-old-key-vault-logs"
    enabled = true

    filters {
      blob_types   = ["blockBlob", "appendBlob"]
      prefix_match = ["insights-logs-auditevent/"]
    }

    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.log_retention_days
      }
    }
  }
}
