###############################################################################
# Azure SQL Database (Basic, 2 GB) + Key Vault + RSA key as TDE protector
# + storage account for SQL auditing and Key Vault audit logs
# Provider: hashicorp/azurerm 5.x
#
# Layout:
#   terraform.tf         versions and provider
#   variables.tf         inputs
#   main.tf              shared data, naming and the module calls
#   outputs.tf           outputs
#   modules/key_vault    vault, keys, secrets, certificate
#   modules/sql          server, TDE, database, firewall rule, SQL auditing
#   modules/monitoring   storage account, Key Vault diagnostics
#
# Before the first apply (one-time per subscription):
#   AzureRM 5.x no longer registers resource providers automatically, so
#   register the ones this configuration needs:
#     az provider register --namespace Microsoft.Sql
#     az provider register --namespace Microsoft.KeyVault
#     az provider register --namespace Microsoft.Storage
#     az provider register --namespace Microsoft.Insights
#
# Run:
#   az login
#   terraform init
#   terraform apply
###############################################################################

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.11"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
