-- =============================================================================
-- CLE: admin vs non-admin test script   (database: cle-database)
--
-- Two sessions are needed. Each block says who runs it:
--   [ADMIN]  connected as the Entra admin or sqladminuser (dbo)
--   [READER] a NEW connection: SQL login user = cle_reader, database = cle-database
--            (VS Code mssql / SSMS: set "Database name" in the connection, not master)
--
-- Run order:  0 (ADMIN)  ->  1 to 7 (READER)  ->  8 (ADMIN)  ->  9 (READER)
--             ->  10 (ADMIN, procedure route)  ->  11 (READER)  ->  12 (ADMIN, cleanup)
--
-- Take one screenshot per numbered test. "Expected" lines are what the lab should show.
-- =============================================================================


-- =============================================================================
-- 0. [ADMIN] Setup: create the non-admin user with minimal rights
-- =============================================================================

-- Contained user: no server login needed, authenticates to this database directly.
CREATE USER cle_reader WITH PASSWORD = '<choose a strong password>';
GO

-- SELECT on the key column and the encrypted column ONLY.
-- Not granted: the plaintext BankAccountNumber column, any key or certificate permission.
GRANT SELECT ON Purchasing.Suppliers (SupplierID, BankAccountNumberEnc) TO cle_reader;
GO

-- Confirm the grants
SELECT dp.name AS grantee, p.permission_name, p.state_desc,
       OBJECT_NAME(p.major_id) AS object_name, c.name AS column_name
FROM sys.database_permissions p
JOIN sys.database_principals dp ON dp.principal_id = p.grantee_principal_id
LEFT JOIN sys.columns c ON c.object_id = p.major_id AND c.column_id = p.minor_id
WHERE dp.name = 'cle_reader';
GO
-- Expected: SELECT on SupplierID and BankAccountNumberEnc, nothing on keys or certificates.


-- =============================================================================
-- 1. [READER] Identity. Compare with the admin check from the baseline.
-- =============================================================================
SELECT SUSER_SNAME()                                                  AS login_name,
       USER_NAME()                                                    AS db_user,
       IS_MEMBER('db_owner')                                          AS is_db_owner,
       HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'CONTROL')            AS has_control,
       DB_NAME()                                                      AS current_db;
GO
-- Expected: db_user = cle_reader, is_db_owner = 0, has_control = 0, current_db = cle-database


-- =============================================================================
-- 2. [READER] Can the user see the encrypted data? (yes: ciphertext only)
-- =============================================================================
SELECT TOP (5) SupplierID, BankAccountNumberEnc AS ciphertext
FROM Purchasing.Suppliers;
GO
-- Expected: rows returned, ciphertext is unreadable bytes.


-- =============================================================================
-- 3. [READER] Can the user read the plaintext column? (no)
-- =============================================================================
SELECT TOP (5) SupplierID, BankAccountNumber
FROM Purchasing.Suppliers;
GO
-- Expected: Msg 230, "The SELECT permission was denied on the column 'BankAccountNumber'".


-- =============================================================================
-- 4. [READER] Open the key. (fails)
-- =============================================================================
OPEN SYMMETRIC KEY CLE_Key DECRYPTION BY CERTIFICATE CLE_Cert;
GO
-- Expected: Msg 15151, "Cannot find the symmetric key 'CLE_Key', because it does not exist
--           or you do not have permission."  (the message does not reveal whether it exists)


-- =============================================================================
-- 5. [READER] Decrypt without opening the key. (silent NULLs, no error)
-- =============================================================================
SELECT TOP (5) SupplierID,
       BankAccountNumberEnc                                       AS ciphertext,
       CONVERT(nvarchar(20), DECRYPTBYKEY(BankAccountNumberEnc))  AS decrypted
FROM Purchasing.Suppliers;
GO
-- Expected: no error, decrypted is NULL on every row.

-- Other decrypt route: DECRYPTBYKEYAUTOCERT, which needs CONTROL on the certificate.
SELECT TOP (5) SupplierID,
       CONVERT(nvarchar(20),
               DECRYPTBYKEYAUTOCERT(CERT_ID('CLE_Cert'), NULL, BankAccountNumberEnc)) AS decrypted
FROM Purchasing.Suppliers;
GO
-- Expected: NULL on every row.


-- =============================================================================
-- 6. [READER] Can the user see or use the key objects? (no)
-- =============================================================================
SELECT name FROM sys.symmetric_keys WHERE name = 'CLE_Key';
SELECT name FROM sys.certificates   WHERE name = 'CLE_Cert';
GO
-- Expected: 0 rows each. Without VIEW DEFINITION the objects are not visible.

SELECT HAS_PERMS_BY_NAME('CLE_Key',  'SYMMETRIC KEY', 'VIEW DEFINITION') AS can_see_key,
       HAS_PERMS_BY_NAME('CLE_Cert', 'CERTIFICATE',   'CONTROL')         AS can_use_cert;
GO
-- Expected: 0 (or NULL) for both.


-- =============================================================================
-- 7. [READER] Can the user change the data? (no)
-- =============================================================================
UPDATE Purchasing.Suppliers SET BankAccountNumberEnc = 0x00 WHERE SupplierID = 1;
GO
-- Expected: Msg 229, "The UPDATE permission was denied on the object 'Suppliers'".


-- =============================================================================
-- 8. [ADMIN] Grant key access, then re-test as the reader
-- =============================================================================
GRANT VIEW DEFINITION ON SYMMETRIC KEY::CLE_Key TO cle_reader;
GRANT CONTROL         ON CERTIFICATE::CLE_Cert  TO cle_reader;
GO


-- =============================================================================
-- 9. [READER] Repeat tests 4 and 5. (now decrypts)
-- =============================================================================
OPEN SYMMETRIC KEY CLE_Key DECRYPTION BY CERTIFICATE CLE_Cert;
SELECT TOP (5) SupplierID,
       BankAccountNumberEnc                                       AS ciphertext,
       CONVERT(nvarchar(20), DECRYPTBYKEY(BankAccountNumberEnc))  AS decrypted
FROM Purchasing.Suppliers;
CLOSE SYMMETRIC KEY CLE_Key;
GO
-- Expected: decrypted shows the real account numbers.
-- Lesson: two grants gave a non-admin full decryption. Grant them sparingly.


-- =============================================================================
-- 10. [ADMIN] Best practice: take the key grants back, give a stored procedure instead
--     The user never touches the key; the procedure runs as the owner (dbo).
--     Note: ownership chaining does NOT cover keys, so EXECUTE AS OWNER is required.
-- =============================================================================
REVOKE VIEW DEFINITION ON SYMMETRIC KEY::CLE_Key FROM cle_reader;
REVOKE CONTROL         ON CERTIFICATE::CLE_Cert  FROM cle_reader;
GO

CREATE OR ALTER PROCEDURE Purchasing.GetSupplierBankAccount @SupplierID int
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    OPEN SYMMETRIC KEY CLE_Key DECRYPTION BY CERTIFICATE CLE_Cert;
    SELECT SupplierID,
           CONVERT(nvarchar(20), DECRYPTBYKEY(BankAccountNumberEnc)) AS BankAccountNumber
    FROM Purchasing.Suppliers
    WHERE SupplierID = @SupplierID;
    CLOSE SYMMETRIC KEY CLE_Key;
END;
GO

GRANT EXECUTE ON Purchasing.GetSupplierBankAccount TO cle_reader;
GO


-- =============================================================================
-- 11. [READER] Use the procedure. (decrypts, with no key permissions)
-- =============================================================================
EXEC Purchasing.GetSupplierBankAccount @SupplierID = 1;
GO
-- Expected: the decrypted account number for supplier 1.

OPEN SYMMETRIC KEY CLE_Key DECRYPTION BY CERTIFICATE CLE_Cert;
GO
-- Expected: still Msg 15151. The user can get one value through the procedure,
--           but still cannot open the key itself.


-- =============================================================================
-- 12. [ADMIN] Cleanup (optional)
-- =============================================================================
-- DROP PROCEDURE Purchasing.GetSupplierBankAccount;
-- DROP USER cle_reader;
