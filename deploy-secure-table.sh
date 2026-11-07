#!/bin/bash
#
# Runs sql/create_table.sql and sql/create_ae_table.sql, which creates
# Purchasing.SuppliersSecure as plaintext, loads 1,000 rows, and adds dynamic
# data masking and sensitivity classifications. Connects with an Entra ID
# access token. Always Encrypted is applied afterwards, in place.
#
# Order:
#   1. terraform apply
#   2. this script
#   3. Deploy-AlwaysEncryptedKeys.ps1: keys, then STEP 15 encrypts two columns
#   4. sql/ae_inplace_encryption.sql encrypts the other two
#
# Requires: az (signed in), terraform, and sqlcmd from mssql-tools18.
#
# Two ways to run it, both from the project root:
#   Automated: ./deploy-secure-table.sh
#   Manual:    paste the setup blocks first, then any block below them, one at a time

# ==========================================
# SETUP: VARIABLES
# ==========================================
# Stops on the first error when run as a script. Skipped when pasted into a
# terminal, where a failed command would otherwise close the terminal.
if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
  set -euo pipefail
fi

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]:-.}")"
TF_DIR="$SCRIPT_DIR/terraform"
SQLCMD_BIN="/opt/homebrew/opt/mssql-tools18/bin/sqlcmd"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'


# ==========================================
# SETUP: READ TERRAFORM OUTPUTS AND VARIABLES
# ==========================================
SQL_SERVER_FQDN=$(terraform -chdir="$TF_DIR" output -raw sql_server_fqdn)
DATABASE_NAME=$(terraform -chdir="$TF_DIR" output -raw database_name)
SUBSCRIPTION_ID=$(echo "var.subscription_id" | terraform -chdir="$TF_DIR" console | tr -d '"')

echo -e "${BLUE}SQL Server: $SQL_SERVER_FQDN${NC}"
echo -e "${BLUE}Database:   $DATABASE_NAME${NC}"


# ==========================================
# SETUP: GET ACCESS TOKEN
# ==========================================
# sqlcmd reads the token from a file, which must be UTF-16LE with no trailing newline.
# The token lasts about an hour. Paste this block again if a manual session expires.
ACCESS_TOKEN_FILE="$(mktemp)"
trap 'rm -f "$ACCESS_TOKEN_FILE"' EXIT

az account get-access-token \
  --subscription "$SUBSCRIPTION_ID" \
  --resource https://database.windows.net/ \
  --query accessToken \
  -o tsv \
  | tr -d '\n' \
  | iconv -f UTF-8 -t UTF-16LE > "$ACCESS_TOKEN_FILE"


# ==========================================
# CREATE THE BASE TABLES
# ==========================================
# Provides the Purchasing schema and SupplierCategories. Safe to run more than once.
echo -e "${YELLOW}Creating base tables...${NC}"

"$SQLCMD_BIN" \
  -S "$SQL_SERVER_FQDN" \
  -d "$DATABASE_NAME" \
  -b \
  -N \
  -G \
  -P "$ACCESS_TOKEN_FILE" \
  -l 30 \
  -i "$SCRIPT_DIR/sql/create_table.sql"


# ==========================================
# CREATE THE SECURE TABLE AND CLASSIFICATIONS
# ==========================================
echo -e "${YELLOW}Creating Purchasing.SuppliersSecure...${NC}"

sqlcmd \
  -S "$SQL_SERVER_FQDN" \
  -d "$DATABASE_NAME" \
  -b \
  -N \
  -G \
  -P "$ACCESS_TOKEN_FILE" \
  -l 30 \
  -i "$SCRIPT_DIR/sql/create_ae_table.sql"


# ==========================================
# VERIFY
# ==========================================
"$SQLCMD_BIN" \
  -S "$SQL_SERVER_FQDN" \
  -d "$DATABASE_NAME" \
  -b \
  -N \
  -G \
  -P "$ACCESS_TOKEN_FILE" \
  -l 30 \
  -W \
  -Q "
SET NOCOUNT ON;

SELECT
    c.name AS column_name,
    c.encryption_type_desc,
    c.is_masked,
    sc.label AS sensitivity_label,
    sc.information_type
FROM sys.columns AS c
LEFT JOIN sys.sensitivity_classifications AS sc
    ON sc.major_id = c.object_id
    AND sc.minor_id = c.column_id
WHERE c.object_id = OBJECT_ID(N'Purchasing.SuppliersSecure')
    AND (c.encryption_type IS NOT NULL OR c.is_masked = 1 OR sc.label IS NOT NULL)
ORDER BY c.column_id;
"

echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}Purchasing.SuppliersSecure deployed.${NC}"
echo -e "${GREEN}==========================================${NC}"


# # ==========================================
# # IN-PLACE ENCRYPTION (run after Deploy-AlwaysEncryptedKeys.ps1)
# # ==========================================
# # sqlcmd can't run this file: its Always Encrypted support only reaches master
# # keys in the Windows Certificate Store, and it can't ask for the enclave.
# # Invoke-Sqlcmd (SqlServer PowerShell module) can, with:
# #   - Column Encryption Setting=Enabled  turns on Always Encrypted
# #   - Attestation Protocol=None          turns on the VBS enclave
# #   - KeyVaultAccessToken                lets the driver unwrap AE_CEK in Key Vault
# #                                        and hand it to the enclave
# # The tokens go in environment variables, which keeps them out of the process list.
# echo -e "${YELLOW}Encrypting BankAccountNumber and BankAccountName in place...${NC}"

# SQL_ACCESS_TOKEN="$(az account get-access-token --subscription "$SUBSCRIPTION_ID" --resource https://database.windows.net/ --query accessToken -o tsv)" \
# KEY_VAULT_TOKEN="$(az account get-access-token --subscription "$SUBSCRIPTION_ID" --resource https://vault.azure.net --query accessToken -o tsv)" \
# SQL_SERVER_FQDN="$SQL_SERVER_FQDN" \
# DATABASE_NAME="$DATABASE_NAME" \
# SQL_FILE="$SCRIPT_DIR/sql/ae_inplace_encryption.sql" \
# pwsh -NoProfile -Command '
# Import-Module SqlServer
# Invoke-Sqlcmd `
#   -ConnectionString "Server=tcp:$env:SQL_SERVER_FQDN,1433;Database=$env:DATABASE_NAME;Encrypt=True;TrustServerCertificate=False;Column Encryption Setting=Enabled;Attestation Protocol=None" `
#   -AccessToken $env:SQL_ACCESS_TOKEN `
#   -KeyVaultAccessToken $env:KEY_VAULT_TOKEN `
#   -InputFile $env:SQL_FILE `
#   -AbortOnError |
#   Format-Table -AutoSize
# '

# echo -e "${GREEN}==========================================${NC}"
# echo -e "${GREEN}In-place encryption complete.${NC}"
# echo -e "${GREEN}==========================================${NC}"
