###############################################################################
# Shared data and naming
###############################################################################

data "azurerm_client_config" "current" {}

# Existing lab resource group; its region is used for every resource
data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

# Public IP of the machine running Terraform, looked up on every plan
data "http" "client_ip" {
  url = "https://api.ipify.org"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Could not look up the client public IP from api.ipify.org."
    }
  }
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  name      = "${var.prefix}-${random_string.suffix.result}"
  location  = data.azurerm_resource_group.rg.location
  client_ip = chomp(data.http.client_ip.response_body)
  tags = {
    purpose = "dp300-lab"
  }
}

###############################################################################
# Modules
###############################################################################

module "key_vault" {
  source = "./modules/key_vault"

  name                = "kv-${local.name}" # 3-24 chars, globally unique
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = local.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  deployer_object_id  = data.azurerm_client_config.current.object_id
  tags                = local.tags
}

module "sql" {
  source = "./modules/sql"

  server_name         = "sql-${local.name}" # globally unique
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = local.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  entra_admin_login   = var.entra_admin_login
  entra_admin_id      = data.azurerm_client_config.current.object_id
  sql_admin_login     = var.sql_admin_login
  sql_admin_password  = module.key_vault.sql_admin_password
  key_vault_id        = module.key_vault.id
  tde_key_id          = module.key_vault.tde_key_id
  client_ip           = local.client_ip
  audit_blob_endpoint = module.monitoring.blob_endpoint
  audit_storage_key   = module.monitoring.audit_storage_key
  log_retention_days  = var.log_retention_days
  tags                = local.tags
}

module "monitoring" {
  source = "./modules/monitoring"

  name                = local.name
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = local.location
  key_vault_id        = module.key_vault.id
  log_retention_days  = var.log_retention_days
  tags                = local.tags
}
