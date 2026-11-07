

# A1. Private working folder (only you can access it)
mkdir -p -m 700 ~/cle && cd ~/cle

# A2. Download the certificate + private key from Key Vault (PFX)
KV=$(cd ~/Downloads/"Implementing TDE, Cell Level Encryption and Always Encrypted/terraform" && terraform output -raw key_vault_name)
az keyvault secret download --vault-name "$KV" --name sql-lab-cert --encoding base64 --file cert.pfx

# A3. Extract the public certificate as DER
openssl pkcs12 -in cert.pfx -passin pass: -nokeys -clcerts | openssl x509 -outform DER -out cert.der

# A4. Extract the private key as PEM (temporary, unencrypted)
openssl pkcs12 -in cert.pfx -passin pass: -nocerts -nodes -out key.pem

# A5. One-off password to protect the key on its way into SQL
PVK_PWD=$(openssl rand -hex 16)

# A6. Convert the private key to PVK, the format SQL accepts
openssl rsa -in key.pem -outform PVK -pvk-strong -passout pass:"$PVK_PWD" -out cert.pvk \
  -provider legacy -provider default

# A7. Write the CREATE CERTIFICATE statement to a file, then open it
printf "CREATE CERTIFICATE CLE_Cert\nFROM BINARY = 0x%s\nWITH PRIVATE KEY (BINARY = 0x%s, DECRYPTION BY PASSWORD = '%s');\n" \
  "$(xxd -p cert.der | tr -d '\n')" "$(xxd -p cert.pvk | tr -d '\n')" "$PVK_PWD" > create_cert.sql
code create_cert.sql

# A8. Get the DMK password (needed for B1)
az keyvault secret show --vault-name "$KV" --name sql-dmk-password --query value -o tsv










-- B1. Database master key
CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<sql-dmk-password from A8>';
GO

-- B2. Import the certificate: run the contents of create_cert.sql (from A7)

-- B3. Verify: thumbprint should match Key Vault; key ENCRYPTED_BY_MASTER_KEY
SELECT name, thumbprint, pvt_key_encryption_type_desc, expiry_date
FROM sys.certificates WHERE name = 'CLE_Cert';
GO

-- B4. Symmetric key, protected by the certificate
CREATE SYMMETRIC KEY CLE_Key WITH ALGORITHM = AES_256
ENCRYPTION BY CERTIFICATE CLE_Cert;
GO

-- B5. Encrypted column on the existing table
ALTER TABLE Purchasing.Suppliers ADD BankAccountNumberEnc varbinary(256) NULL;
GO

-- B6. Encrypt the existing values
OPEN SYMMETRIC KEY CLE_Key DECRYPTION BY CERTIFICATE CLE_Cert;
UPDATE Purchasing.Suppliers
   SET BankAccountNumberEnc = ENCRYPTBYKEY(KEY_GUID('CLE_Key'), BankAccountNumber)
 WHERE BankAccountNumber IS NOT NULL;
CLOSE SYMMETRIC KEY CLE_Key;
GO

-- B7. Test: plaintext and decrypted should match
OPEN SYMMETRIC KEY CLE_Key DECRYPTION BY CERTIFICATE CLE_Cert;
SELECT TOP (5) SupplierID,
       BankAccountNumber                                          AS plaintext,
       BankAccountNumberEnc                                       AS ciphertext,
       CONVERT(nvarchar(20), DECRYPTBYKEY(BankAccountNumberEnc))  AS decrypted
FROM Purchasing.Suppliers;
CLOSE SYMMETRIC KEY CLE_Key;


-- =============================================================================
-- PART C: Non-admin user, to prove admin vs non-admin access
-- Admin (server admin / Entra admin) maps to dbo and can always decrypt.
-- The non-admin user can only do what we GRANT.
-- =============================================================================

-- C1. Create the non-admin user.
--     Run as the ADMIN, connected to cle-database (not master).
--     A contained user needs no server login; it authenticates to the database directly.
CREATE USER cle_reader WITH PASSWORD = '<choose a strong password>';
GO

-- C2. Give it SELECT on the encrypted column only (not the plaintext BankAccountNumber)
--     and no permission on the key or certificate.
GRANT SELECT ON Purchasing.Suppliers (SupplierID, BankAccountNumberEnc) TO cle_reader;
GO

-- C3. Confirm who you are. Run in EACH session before the tests below.
--     Admin session      -> dbo,        is_db_owner = 1
--     cle_reader session -> cle_reader, is_db_owner = 0
SELECT USER_NAME() AS db_user, IS_MEMBER('db_owner') AS is_db_owner;
GO

-- C4. Test as cle_reader.
--     Open a NEW connection: user cle_reader, the password from C1, database cle-database.
--     (SSMS: Options >> Connection Properties >> Connect to database = cle-database)

--     Expected: error Msg 15151 "Cannot find the symmetric key 'CLE_Key', because it does
--     not exist or you do not have permission."
OPEN SYMMETRIC KEY CLE_Key DECRYPTION BY CERTIFICATE CLE_Cert;
GO

--     Expected: no error, but every row returns NULL for decrypted
--     (cle_reader can read the ciphertext, never the plaintext).
SELECT TOP (5) SupplierID,
       BankAccountNumberEnc                                       AS ciphertext,
       CONVERT(nvarchar(20), DECRYPTBYKEY(BankAccountNumberEnc))  AS decrypted
FROM Purchasing.Suppliers;
GO

-- C5. Test as the ADMIN: run B7 again. The decrypted column matches the plaintext.

-- C6. (Optional) Grant key access to cle_reader, then repeat C4: it now decrypts.
--     Run as the ADMIN.
-- GRANT VIEW DEFINITION ON SYMMETRIC KEY::CLE_Key TO cle_reader;
-- GRANT CONTROL         ON CERTIFICATE::CLE_Cert  TO cle_reader;

-- C7. (Cleanup) Run as the ADMIN when finished.
-- DROP USER cle_reader;
