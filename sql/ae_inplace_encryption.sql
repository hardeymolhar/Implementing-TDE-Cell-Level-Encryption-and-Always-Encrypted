/* ============================================================
   In-place encryption with T-SQL: the server-side route.
   Encrypts two columns of Purchasing.SuppliersSecure inside the secure
   enclave, so the data never leaves the database:
     BankAccountNumber   deterministic (equality searches)
     BankAccountName     randomized
   The other two bank columns are encrypted by the client-side route,
   Set-SqlColumnEncryption in Deploy-AlwaysEncryptedKeys STEP 15.

   Requirements:
     - create_ae_table.sql has run (table exists, rows loaded)
     - AE_CEK exists, under an enclave-enabled AE_CMK (Deploy-AlwaysEncryptedKeys)
     - the database has a VBS enclave (Terraform enclave_type = "VBS")
     - the connection has Always Encrypted AND enclave computations on,
       for example Microsoft.Data.SqlClient with
       "Column Encryption Setting=Enabled; Attestation Protocol=None",
       or SSMS with Always Encrypted and secure enclaves turned on.
       sqlcmd can't make this connection.
   Safe to run more than once: encrypted columns are skipped.
   ============================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* 1. Check the key is enclave-enabled */
IF NOT EXISTS
(
    SELECT 1
    FROM sys.column_encryption_keys AS k
    JOIN sys.column_encryption_key_values AS v
        ON v.column_encryption_key_id = k.column_encryption_key_id
    JOIN sys.column_master_keys AS m
        ON m.column_master_key_id = v.column_master_key_id
    WHERE k.name = 'AE_CEK'
      AND m.allow_enclave_computations = 1
)
    THROW 50000, 'AE_CEK not found, or its AE_CMK is not enclave-enabled. Run Deploy-AlwaysEncryptedKeys first.', 1;
GO

/* 2. Encrypt BankAccountNumber (deterministic) */
IF EXISTS
(
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID(N'Purchasing.SuppliersSecure')
      AND name = N'BankAccountNumber'
      AND encryption_type IS NULL
)
    ALTER TABLE Purchasing.SuppliersSecure
    ALTER COLUMN BankAccountNumber nvarchar(20)
        COLLATE Latin1_General_BIN2
        ENCRYPTED WITH
        (
            COLUMN_ENCRYPTION_KEY = AE_CEK,
            ENCRYPTION_TYPE = DETERMINISTIC,
            ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256'
        )
        NULL;
GO

/* 3. Encrypt BankAccountName (randomized) */
IF EXISTS
(
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID(N'Purchasing.SuppliersSecure')
      AND name = N'BankAccountName'
      AND encryption_type IS NULL
)
    ALTER TABLE Purchasing.SuppliersSecure
    ALTER COLUMN BankAccountName nvarchar(50)
        COLLATE Latin1_General_BIN2
        ENCRYPTED WITH
        (
            COLUMN_ENCRYPTION_KEY = AE_CEK,
            ENCRYPTION_TYPE = RANDOMIZED,
            ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256'
        )
        NULL;
GO

/* 4. Clear cached plans, so queries pick up the new encryption metadata */
ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
GO

/* 5. Index the deterministic column, now that it holds ciphertext */
IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'Purchasing.SuppliersSecure')
      AND name = N'IX_Purchasing_SuppliersSecure_BankAccountNumber'
)
    CREATE NONCLUSTERED INDEX IX_Purchasing_SuppliersSecure_BankAccountNumber
        ON Purchasing.SuppliersSecure (BankAccountNumber);
GO

/* 6. Verify: encryption type per bank column, and classifications kept */
SELECT c.name AS column_name,
       c.encryption_type_desc,
       sc.label AS sensitivity_label
FROM sys.columns AS c
LEFT JOIN sys.sensitivity_classifications AS sc
    ON sc.major_id = c.object_id
    AND sc.minor_id = c.column_id
WHERE c.object_id = OBJECT_ID(N'Purchasing.SuppliersSecure')
  AND c.name LIKE N'Bank%'
ORDER BY c.column_id;
GO
