terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

###############################################################################
# Key Vault
#   - Vault access policy permission model (rbac_authorization_enabled = false)
#   - Purge protection is mandatory for a TDE protector
#   - Access policies are standalone resources; don't also add inline
#     access_policy blocks here, or the two will overwrite each other
###############################################################################

resource "azurerm_key_vault" "kv" {
  name                          = var.name
  location                      = var.location
  resource_group_name           = var.resource_group_name
  tenant_id                     = var.tenant_id
  sku_name                      = "standard" # use "premium" for HSM-protected keys (RSA-HSM)
  rbac_authorization_enabled    = false      # use access policies instead of Azure RBAC
  purge_protection_enabled      = true
  soft_delete_retention_days    = 7 # minimum; cannot be changed after creation
  public_network_access_enabled = true
  tags                          = var.tags
}

# Lets the identity running Terraform manage keys, secrets and certificates.
# GetRotationPolicy is needed because the provider reads each key's rotation policy.
# WrapKey/UnwrapKey/Sign/Verify also let this identity use the Always Encrypted
# column master key from SSMS.
resource "azurerm_key_vault_access_policy" "deployer" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = var.tenant_id
  object_id    = var.deployer_object_id

  key_permissions = [
    "Get", "List", "Create", "Update", "Import", "Delete", "Recover", "Purge",
    "Backup", "Restore", "GetRotationPolicy", "SetRotationPolicy",
    "WrapKey", "UnwrapKey", "Sign", "Verify",
  ]

  secret_permissions = [
    "Get", "List", "Set", "Delete", "Recover", "Purge", "Backup", "Restore",
  ]

  certificate_permissions = [
    "Get", "List", "Create", "Update", "Import", "Delete", "Recover", "Purge",
    "Backup", "Restore", "GetIssuers", "ListIssuers", "SetIssuers",
    "DeleteIssuers", "ManageIssuers", "ManageContacts",
  ]
}

###############################################################################
# RSA key - asymmetric key suitable as the TDE protector
#   RSA 2048 or 3072, wrapKey/unwrapKey are the operations TDE uses
###############################################################################

resource "azurerm_key_vault_key" "tde" {
  name         = "tde-protector"
  key_vault_id = azurerm_key_vault.kv.id
  key_type     = "RSA" # "RSA-HSM" with a premium vault
  key_size     = 3072
  key_opts     = ["wrapKey", "unwrapKey"]

  depends_on = [azurerm_key_vault_access_policy.deployer]
}

# Column master key for Always Encrypted (used by client apps / SSMS, not the server)
resource "azurerm_key_vault_key" "ae_cmk" {
  name         = "ae-column-master-key"
  key_vault_id = azurerm_key_vault.kv.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["wrapKey", "unwrapKey", "sign", "verify"]

  depends_on = [azurerm_key_vault_access_policy.deployer]
}

###############################################################################
# SQL admin password stored as a Key Vault secret
#   1. random_password generates it (meets Azure SQL complexity rules)
#   2. azurerm_key_vault_secret stores it in the vault
#   3. the data source reads it back from the vault, and the SQL module
#      takes its password from there (via the sql_admin_password output)
###############################################################################

resource "random_password" "sql_admin" {
  length           = 24
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!#%*-_+="
}

resource "azurerm_key_vault_secret" "sql_admin_password" {
  name         = "sql-admin-password"
  key_vault_id = azurerm_key_vault.kv.id
  value        = random_password.sql_admin.result
  content_type = "password"

  depends_on = [azurerm_key_vault_access_policy.deployer]
}

data "azurerm_key_vault_secret" "sql_admin_password" {
  name         = azurerm_key_vault_secret.sql_admin_password.name
  key_vault_id = azurerm_key_vault.kv.id
}

###############################################################################
# Database master key password (for cell-level encryption)
###############################################################################

resource "random_password" "dmk" {
  length           = 32
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!#%*-_+="
}

resource "azurerm_key_vault_secret" "dmk_password" {
  name         = "sql-dmk-password"
  key_vault_id = azurerm_key_vault.kv.id
  value        = random_password.dmk.result
  content_type = "password"

  depends_on = [azurerm_key_vault_access_policy.deployer]
}

###############################################################################
# Certificate (self-signed, auto-renewing)
###############################################################################

resource "azurerm_key_vault_certificate" "sql_lab" {
  name         = "sql-lab-cert"
  key_vault_id = azurerm_key_vault.kv.id

  certificate_policy {
    issuer_parameters {
      name = "Self"
    }

    key_properties {
      exportable = true
      key_type   = "RSA"
      key_size   = 2048
      reuse_key  = false
    }

    lifetime_action {
      action {
        action_type = "AutoRenew"
      }
      trigger {
        days_before_expiry = 30
      }
    }

    secret_properties {
      content_type = "application/x-pkcs12"
    }

    x509_certificate_properties {
      subject            = "CN=sql-lab"
      validity_in_months = 12
      key_usage          = ["digitalSignature", "keyEncipherment", "dataEncipherment"]
    }
  }

  depends_on = [azurerm_key_vault_access_policy.deployer]
}
