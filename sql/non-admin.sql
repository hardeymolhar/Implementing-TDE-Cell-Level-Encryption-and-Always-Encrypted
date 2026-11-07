

-- =====================================================================
-- Run everything in YOUR ADMIN session, connected to cle-database.
-- Pattern: impersonate -> test -> REVERT -> (admin) GRANT -> impersonate again
-- =====================================================================

-- 1. Prove you are impersonating (db_user must be cle_reader, not dbo)
EXECUTE AS USER = 'cle_reader';
GO
SELECT USER_NAME()                                          AS db_user,
       IS_MEMBER('db_owner')                                AS is_db_owner,
       HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'CONTROL')  AS has_control;
GO
REVERT;
GO


-- 2. Read the ciphertext (should work: SELECT was granted)
EXECUTE AS USER = 'cle_reader';
GO
SELECT TOP (5) SupplierID, BankAccountNumberEnc AS ciphertext
FROM Purchasing.Suppliers;
GO
REVERT;
GO
-- Expected: rows, unreadable bytes.


-- 3. Decrypt without opening the key (no error, silent NULLs)
EXECUTE AS USER = 'cle_reader';
GO
SELECT TOP (5) SupplierID,
       CONVERT(nvarchar(20), DECRYPTBYKEY(BankAccountNumberEnc)) AS decrypted
FROM Purchasing.Suppliers;
GO
REVERT;
GO
-- Expected: decrypted = NULL on every row.


-- 4. ERROR 1: open the key
EXECUTE AS USER = 'cle_reader';
GO
OPEN SYMMETRIC KEY CLE_Key DECRYPTION BY CERTIFICATE CLE_Cert;
GO
REVERT;
GO
-- Expected: Msg 15151, cannot find the symmetric key 'CLE_Key' ... or you do not have permission.

-- FIX 1 (admin): let the user see and use the key
GRANT VIEW DEFINITION ON SYMMETRIC KEY::CLE_Key TO cle_reader;
GO


-- 6. ERROR 2: retry. The key is now visible, but the certificate is not usable yet
EXECUTE AS USER = 'cle_reader';
GO
OPEN SYMMETRIC KEY CLE_Key DECRYPTION BY CERTIFICATE CLE_Cert;
GO
REVERT;
GO
-- Expected: still an error, this time about the certificate 'CLE_Cert' (no permission).

-- FIX 2 (admin): the second grant
GRANT CONTROL ON CERTIFICATE::CLE_Cert TO cle_reader;
GO


-- 7. SUCCESS: retry. Open, decrypt, close
EXECUTE AS USER = 'cle_reader';
GO
OPEN SYMMETRIC KEY CLE_Key DECRYPTION BY CERTIFICATE CLE_Cert;
SELECT TOP (5) SupplierID,
       BankAccountNumberEnc                                      AS ciphertext,
       CONVERT(nvarchar(20), DECRYPTBYKEY(BankAccountNumberEnc)) AS decrypted
FROM Purchasing.Suppliers;
CLOSE SYMMETRIC KEY CLE_Key;
GO
REVERT;
GO
-- Expected: decrypted shows the real account numbers.


-- 8. Take the grants back (admin), then show it fails again
REVOKE VIEW DEFINITION ON SYMMETRIC KEY::CLE_Key FROM cle_reader;
REVOKE CONTROL         ON CERTIFICATE::CLE_Cert  FROM cle_reader;
CLOSE ALL SYMMETRIC KEYS;
GO
EXECUTE AS USER = 'cle_reader';
GO
OPEN SYMMETRIC KEY CLE_Key DECRYPTION BY CERTIFICATE CLE_Cert;
GO
REVERT;
GO
-- Expected: Msg 15151 again.

