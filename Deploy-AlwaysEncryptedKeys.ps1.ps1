<#
=============================================================================
  encrypted-cek.ps1 — Provision the Always Encrypted key hierarchy
=============================================================================

WHAT THIS SCRIPT DOES (in one sentence):
  It creates the two keys that make Always Encrypted work — a Column Master
  Key (CMK) and a Column Encryption Key (CEK) — and registers them in the
  database. It does NOT encrypt any table data; the application does that
  later, using the CEK created here.

WHY ALWAYS ENCRYPTED IS DIFFERENT (read this first):
  With Always Encrypted, the *client driver* (Microsoft.Data.SqlClient)
  encrypts and decrypts the protected columns — NOT SQL Server. The server
  only ever receives, stores, and returns ciphertext, and it cannot read it.
  That is why the data is protected even from a database administrator, or
  from anyone who can read the database files: without access to the master
  key in Key Vault, the ciphertext is meaningless.

THE TWO-KEY HIERARCHY (a.k.a. envelope encryption / key wrapping):

  - CMK = Column Master Key
      An RSA key that lives in Azure Key Vault and NEVER leaves it. SQL Server
      stores only a *pointer* to it (the Key Vault URL), never the key itself.
      Its only job is to encrypt ("wrap") the CEK.

  - CEK = Column Encryption Key
      The AES-256 key that actually encrypts the column values. It is stored
      *inside the database*, but only in wrapped form (encrypted by the CMK).
      The plaintext CEK exists only briefly, in the client's memory, after the
      driver asks Key Vault to unwrap it.

  Why two keys instead of one?
    1. Rotation: to rotate the master key you only re-wrap the small CEK — you
       do NOT have to re-encrypt every row in every table.
    2. Separation of duties: a DBA can manage the database yet still cannot
       decrypt the data, because decrypting requires Key Vault access to the
       CMK, which is granted separately.

HOW THE PIECES FIT TOGETHER:

  Azure Key Vault            SQL Database                Client driver
  ┌──────────────┐         ┌──────────────────┐       ┌──────────────────┐
  │ CMK (RSA)    │── wrap ─▶│ CEK (encrypted)  │       │ plaintext CEK    │
  │ private key  │         │ + column metadata │── ✗ ─▶│ (memory only)    │
  │ NEVER leaves │◀─unwrap ─│ ciphertext only  │◀─ TLS ▶│ encrypt/decrypt  │
  │ the vault    │         └──────────────────┘       │ column values    │
  └──────────────┘                                     └──────────────────┘
   The server holds only a pointer to the CMK and the *wrapped* CEK — it
   never sees the plaintext CEK (the ✗) nor the plaintext data.

WHERE STEP 14 BELOW IS ITSELF CLIENT-SIDE ENCRYPTION:
  Creating the CEK (STEP 14) is the clearest example of the client doing the
  crypto: this PowerShell process generates a random AES-256 CEK, sends it to
  Key Vault to be wrapped by the RSA CMK, and stores ONLY the wrapped result in
  the database. The server never sees the plaintext CEK. The .NET workload
  later performs the same kind of client-side operation on every row value.
=============================================================================
#>

# =========================================================
# PREREQUISITES — Find the resource group
# =========================================================
# WHAT: take the first resource group returned by 'az group list' ([0]).
# WHY:  there is no resource suffix any more, so nothing is matched by name;
#       the later 'az' lookups just need a resource group to scope their queries.
$resourceGroup = az group list `
  --query "[1].name" `
  -o tsv

# =========================================================
# REQUIRED MODULES
# =========================================================
# WHAT: import the Azure + SQL PowerShell modules this script depends on.
# WHY:  Az.Accounts provides the Azure sign-in context; Az.KeyVault reads the
#       CMK from Key Vault (STEP 8); SqlServer provides the Always Encrypted
#       cmdlets used in STEPs 9, 13 and 14 (New-Sql...ColumnMasterKey / ...Key).
Import-Module Az.Accounts
Import-Module Az.KeyVault
Import-Module SqlServer

# =========================================================
# REQUIRED .NET ASSEMBLIES
# =========================================================
# WHAT: load the .NET types the connection and cmdlets use directly.
# WHY:  Microsoft.Data.SqlClient IS the client driver that performs the Always
#       Encrypted crypto — it wraps the CEK here, and (in the .NET app) encrypts
#       parameters / decrypts results. SMO + ConnectionInfo provide the
#       Server/Database objects the New-SqlColumn...Key cmdlets operate on (STEP 11).
Add-Type -AssemblyName "Microsoft.Data.SqlClient"
Add-Type -AssemblyName "Microsoft.SqlServer.Smo"
Add-Type -AssemblyName "Microsoft.SqlServer.ConnectionInfo"
# =========================================================
# STEP 1 — Discover SQL Server
# =========================================================
# WHAT: take the first SQL logical server in the resource group.
# WHY:  avoids hardcoding the server name; feeds STEPs 2-4 and the connection
#       string.
$sqlServerName = (az sql server list `
  --resource-group "$resourceGroup" `
  --query "[0].name" `
  -o tsv)



# =========================================================
# STEP 2 — Discover Resource Group
# =========================================================
# WHAT: look up the resource group that actually contains that SQL server.
# WHY:  confirms/normalizes the RG name used by the remaining az lookups.
$resourceGroup = az sql server list `
    --query "[?name=='$sqlServerName'].resourceGroup | [0]" `
    -o tsv


# =========================================================
# STEP 3 — Retrieve SQL Server FQDN
# =========================================================
# WHAT: get the server's fully qualified domain name (e.g. xxx.database.windows.net).
# WHY:  STEP 10 must dial the real DNS name, not the short server name.
$serverName = az sql server show `
    --name $sqlServerName `
    --resource-group $resourceGroup `
    --query fullyQualifiedDomainName `
    -o tsv


# =========================================================
# STEP 4 — Database Name (manual input)
# =========================================================
# WHAT: prompt for the database name instead of discovering it.
# WHY:  CMK/CEK metadata is created per user database; the operator chooses
#       which one, so it is never guessed from the server's database list.
$databaseName = "cle-database"  # <-- CHANGE THIS to the target database name


# =========================================================
# STEP 5 — Acquire Azure SQL Access Token
# =========================================================
# WHAT: get an Entra ID (AAD) access token scoped to Azure SQL (database.windows.net).
# WHY:  STEP 10 authenticates to SQL with this token instead of a SQL
#       username/password — an Entra ID identity, with no stored secret.
# $token = az account get-access-token `
#     --resource https://database.windows.net/ `
#     --query accessToken `
#     -o tsv

    # SQL Server authentication
$sqlAdmin = "sqladminuser"

$sqlPassword = ConvertTo-SecureString `
    "0aYrkpkuSW7_Zt*fEJcvDL=E" `
    -AsPlainText -Force
# Mark password as read-only
$sqlPassword.MakeReadOnly()

$sqlCredential = [Microsoft.Data.SqlClient.SqlCredential]::new(
    $sqlAdmin,
    $sqlPassword
)


# =========================================================
# STEP 6 — Discover Key Vault
# =========================================================
# WHAT: find the Key Vault in the resource group.
# WHY:  that vault holds the CMK (the RSA master key); STEP 8 reads it from here.
$keyVaultName = az keyvault list `
    --resource-group $resourceGroup `
    --query "[0].name" `
    -o tsv


# =========================================================
# STEP 7 — Define Always Encrypted Objects
# =========================================================
# WHAT: name the keys. $keyName is the PHYSICAL RSA key inside Key Vault;
#       $cmkName / $cekName are the LOGICAL names registered in the database.
# WHY:  column DDL references the logical names (e.g. COLUMN_ENCRYPTION_KEY =
#       AE_CEK), keeping table definitions independent of where the key
#       physically lives in Key Vault.
$keyName = "ae-column-master-key"

$cmkName = "AE_CMK"

$cekName = "AE_CEK"


# =========================================================
# STEP 8 — Retrieve Key Vault CMK
# =========================================================
# WHAT: read the key object from Key Vault and capture its Key Identifier URL
#       ($key.Key.Kid) — the full https://...vault.../keys/<name>/<version> address.
# WHY:  SQL never stores the master key itself, only this URL (a pointer). The
#       private key stays in Key Vault; clients use the URL to ask Key Vault to
#       wrap/unwrap the CEK.
$key = Get-AzKeyVaultKey `
    -VaultName $keyVaultName `
    -Name $keyName

$keyPath = $key.Key.Kid


# =========================================================
# STEP 9 — Create CMK Settings Object
# =========================================================
# WHAT: build an in-memory settings object describing the CMK: provider type =
#       Azure Key Vault, location = the key URL from STEP 8.
# WHY:  this is the metadata STEP 13 writes into the database. It tells any
#       client driver WHERE the master key is and HOW to reach it (provider
#       AZURE_KEY_VAULT) — location only, no key material.
#       -AllowEnclaveComputations marks the CMK enclave-enabled: the client may
#       then share keys it protects with the server's secure enclave, which is
#       what in-place encryption (STEP 15, sql/ae_inplace_encryption.sql) needs.
#       To do that, the cmdlet SIGNS the settings with the key in Key Vault, so
#       it needs a Key Vault token here. A SQL token (audience database.windows.net)
#       can't call Key Vault (audience vault.azure.net): each service needs its own.
#       STEPs 14 and 15 reuse this same token.
$keyVaultToken = az account get-access-token `
    --resource https://vault.azure.net `
    --query accessToken `
    -o tsv

$cmkSettings = New-SqlAzureKeyVaultColumnMasterKeySettings `
    -KeyUrl $keyPath `
    -AllowEnclaveComputations `
    -KeyVaultAccessToken $keyVaultToken


# =========================================================
# STEP 10 — Create SQL  Connection
# =========================================================
# WHAT: open a Microsoft.Data.SqlClient connection to the database, authenticated
#       with the STEP 5 token.
# WHY:  this is the literal "client driver." The connection-string keywords below
#       control its behavior:
#         - Column Encryption Setting=Enabled -> arms Always Encrypted: the driver
#           will wrap the CEK here, and (in the app) encrypt parameters and decrypt
#           results. THIS is the switch that turns on client-side crypto.
#         - Encrypt=True / TrustServerCertificate=False -> TLS in transit with a
#           validated server certificate. This protects data ON THE WIRE and is
#           SEPARATE from Always Encrypted (which protects the column values
#           themselves, end to end).
#         - Attestation Protocol=None -> enables enclave computations over a
#           VBS enclave in Azure SQL, which doesn't use attestation. Without
#           it, in-place encryption is refused.
#       NOTE: the @"..."@ here-string IS the literal connection string — do not put
#       comments inside it, or they become part of the string.
# $sqlConnection = New-Object Microsoft.Data.SqlClient.SqlConnection

# $sqlConnection.ConnectionString = @"

# Server=tcp:$serverName,1433;

# Database=$databaseName;

# Encrypt=True;

# TrustServerCertificate=False;

# Attestation Protocol=None;

# Column Encryption Setting=Enabled;

# "@

# $sqlConnection.AccessToken = $token

# $sqlConnection.Open()

# Create SQL connection using SQL Server authentication

# STEP 10 — SQL Authentication Connection String

$sqlAdmin = "sqladminuser"

# Hardcoded password
$sqlPasswordPlain = "0aYrkpkuSW7_Zt*fEJcvDL=E"

$sqlConnectionString = @"
Server=tcp:$serverName,1433;
Database=$databaseName;
User ID=$sqlAdmin;
Password=$sqlPasswordPlain;
Encrypt=True;
TrustServerCertificate=False;
Attestation Protocol=None;
"@

# STEP 11 — Retrieve SMO Database Object

$database = Get-SqlDatabase `
    -ConnectionString $sqlConnectionString `
    -Name $databaseName `
    -ErrorAction Stop

if ($null -eq $database) {
    throw "Database '$databaseName' was not found."
}

Write-Host "Connected to database: $($database.Name)"

# $sqlConnectionString = @"
# Server=tcp:$serverName,1433;
# Database=$databaseName;
# Encrypt=True;
# TrustServerCertificate=False;
# Attestation Protocol=None;
# Column Encryption Setting=Enabled;
# "@

# $sqlConnection = [Microsoft.Data.SqlClient.SqlConnection]::new(
#     $sqlConnectionString,
#     $sqlCredential
# )

# $sqlConnection.Open()

# Write-Host "Connected to Azure SQL using SQL authentication."

# # =========================================================
# # STEP 11 — Create SQL SMO Server Object
# # =========================================================
# # WHAT: wrap the open connection in SMO (ServerConnection -> Server -> Database),
# #       then verify the target database exists.
# # WHY:  the New-SqlColumnMasterKey / New-SqlColumnEncryptionKey cmdlets operate on
# #       an SMO Database object (-InputObject), not a raw connection string. Reusing
# #       the already-open, Always-Encrypted-enabled connection means the cmdlets
# #       inherit the same Entra ID auth and encryption settings.
# $serverConnection = New-Object Microsoft.SqlServer.Management.Common.ServerConnection -ArgumentList $sqlConnection

# $server = New-Object Microsoft.SqlServer.Management.Smo.Server -ArgumentList $serverConnection


# $database = $server.Databases[$databaseName]

# if ($null -eq $database) {
#     throw "Database '$databaseName' was not found on server '$serverName'."
# }



# =========================================================
# STEP 13 — Create Column Master Key Metadata
#   (there is no STEP 12 — just a numbering gap, not a missing action)
# =========================================================
# WHAT: register the CMK in the database (writes a row to sys.column_master_keys)
#       using the settings from STEP 9, including their enclave signature.
# WHY:  the CMK row records the pointer to the Key Vault key + the provider that
#       unwraps it, so any client knows where to get the master key.
New-SqlColumnMasterKey `
    -Name $cmkName `
    -InputObject $database `
    -ColumnMasterKeySettings $cmkSettings


# =========================================================
# STEP 14 — Create Column Encryption Key
# =========================================================
# WHAT: create the CEK. Under the hood the client driver:
#         1. generates a fresh random AES-256 key (the plaintext CEK), in memory;
#         2. sends it to Key Vault (using $keyVaultToken) to be ENCRYPTED ("wrapped")
#            by the RSA CMK;
#         3. stores ONLY the wrapped (encrypted) CEK in the database
#            (sys.column_encryption_keys) — never the plaintext.
# WHY:  this is client-side encryption in miniature. The plaintext CEK never
#       reaches SQL Server, so the server can store the key yet never use it. This
#       same CEK (AE_CEK) is what column DDL references, and what the .NET app
#       later unwraps to encrypt/decrypt actual row values. SQL Server can never
#       read it, because reading it requires Key Vault access to the CMK.
New-SqlColumnEncryptionKey `
    -Name $cekName `
    -InputObject $database `
    -ColumnMasterKey $cmkName `
    -KeyVaultAccessToken $keyVaultToken


# =========================================================
# STEP 15 — Encrypt Existing Columns In Place (cmdlet route)
# =========================================================
# WHAT: encrypt two columns that already hold data in Purchasing.SuppliersSecure
#       (created and loaded by sql/create_ae_table.sql). Each
#       New-SqlColumnEncryptionSettings names ONE column: which column, which
#       encryption type, which CEK. Columns not listed are left alone.
# WHY:  this is the PowerShell route to in-place encryption. The cmdlet sends the
#       CEK to the server's secure enclave, and the enclave encrypts the data
#       inside the database. The other two bank columns use the T-SQL route,
#       sql/ae_inplace_encryption.sql, so both routes can be compared.
#       -DisableFallBackToClientSide makes it fail rather than quietly download
#       every row and encrypt it on this machine if the enclave can't be used.
$columnSettings = @(
    New-SqlColumnEncryptionSettings `
        -ColumnName "Purchasing.SuppliersSecure.BankAccountCode" `
        -EncryptionType "Randomized" `
        -EncryptionKey $cekName

    New-SqlColumnEncryptionSettings `
        -ColumnName "Purchasing.SuppliersSecure.BankInternationalCode" `
        -EncryptionType "Randomized" `
        -EncryptionKey $cekName

    New-SqlColumnEncryptionSettings `
        -ColumnName "Purchasing.SuppliersSecure.BankAccountNumber" `
        -EncryptionType "Randomized" `
        -EncryptionKey $cekName

    New-SqlColumnEncryptionSettings `
        -ColumnName "Purchasing.SuppliersSecure.BankAccountName" `
        -EncryptionType "Randomized" `
        -EncryptionKey $cekName
)

Set-SqlColumnEncryption `
    -InputObject $database `
    -ColumnEncryptionSettings $columnSettings `
    -KeyVaultAccessToken $keyVaultToken `
    -EnclaveAttestationProtocol None `
    -DisableFallBackToClientSide `
    -LogFileDirectory .
