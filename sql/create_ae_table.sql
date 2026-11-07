/* ============================================================
   Purchasing.SuppliersSecure: the Purchasing.Suppliers design from
   create_table.sql, created as PLAINTEXT, loaded with 1,000 fake rows and
   classified. Always Encrypted is added afterwards, in place:
     sql/ae_inplace_encryption.sql       BankAccountNumber, BankAccountName
     Deploy-AlwaysEncryptedKeys STEP 15  BankAccountCode, BankInternationalCode
   Differences from Purchasing.Suppliers, for in-place encryption:
     - no temporal history
     - the four bank columns use a BIN2 collation
     - the BankAccountNumber index is created after encryption
   Run create_table.sql first. Safe to run more than once.
   ============================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;   -- required for the filtered index; ODBC sqlcmd defaults it to OFF
GO


IF SCHEMA_ID(N'Purchasing') IS NULL
    EXEC (N'CREATE SCHEMA Purchasing AUTHORIZATION dbo;');
GO

/* 1. Table (plaintext) */
IF OBJECT_ID(N'Purchasing.SuppliersSecure', N'U') IS NULL
BEGIN
    CREATE TABLE Purchasing.SuppliersSecure
    (
        SupplierID            int IDENTITY(1,1) NOT NULL,
        SupplierName          nvarchar(100)     NOT NULL,
        SupplierCategoryID    int               NOT NULL,
        SupplierReference     nvarchar(20)      NULL,

        /* Bank columns: plaintext for now. BIN2 is required for deterministic
           encryption, and for comparisons on enclave-enabled columns. */
        BankAccountNumber     nvarchar(20)  COLLATE Latin1_General_BIN2 NULL,
        BankAccountName       nvarchar(50)  COLLATE Latin1_General_BIN2 NULL,
        BankAccountCode       nvarchar(20)  COLLATE Latin1_General_BIN2 NULL,
        BankInternationalCode nvarchar(20)  COLLATE Latin1_General_BIN2 NULL,
        BankAccountBranch     nvarchar(50)      NULL,

        PaymentDays           int               NOT NULL
            CONSTRAINT DF_Purchasing_SuppliersSecure_PaymentDays DEFAULT (30),
        InternalComments      nvarchar(max)     NULL,

        /* Masked: readers without the UNMASK permission see a partial value */
        PhoneNumber           nvarchar(20)
            MASKED WITH (FUNCTION = 'partial(0,"XXX-XXX-",4)')
            NULL,

        WebsiteURL            nvarchar(256)     NULL,
        DeliveryAddressLine1  nvarchar(60)      NOT NULL,
        DeliveryAddressLine2  nvarchar(60)      NULL,
        DeliveryPostalCode    nvarchar(10)      NOT NULL,

        IsActive              bit               NOT NULL
            CONSTRAINT DF_Purchasing_SuppliersSecure_IsActive DEFAULT (1),
        CreatedAtUtc          datetime2(3)      NOT NULL
            CONSTRAINT DF_Purchasing_SuppliersSecure_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy             nvarchar(128)
            MASKED WITH (FUNCTION = 'partial(1,"****",1)')
            NOT NULL
            CONSTRAINT DF_Purchasing_SuppliersSecure_CreatedBy DEFAULT (SUSER_SNAME()),

        CONSTRAINT PK_Purchasing_SuppliersSecure
            PRIMARY KEY CLUSTERED (SupplierID),
        CONSTRAINT UQ_Purchasing_SuppliersSecure_SupplierName
            UNIQUE (SupplierName),
        CONSTRAINT FK_Purchasing_SuppliersSecure_SupplierCategories
            FOREIGN KEY (SupplierCategoryID)
            REFERENCES Purchasing.SupplierCategories (SupplierCategoryID),
        CONSTRAINT CK_Purchasing_SuppliersSecure_PaymentDays
            CHECK (PaymentDays BETWEEN 0 AND 365),
        CONSTRAINT CK_Purchasing_SuppliersSecure_Name_NotBlank
            CHECK (LEN(LTRIM(RTRIM(SupplierName))) > 0)
    );

    CREATE NONCLUSTERED INDEX IX_Purchasing_SuppliersSecure_SupplierCategoryID
        ON Purchasing.SuppliersSecure (SupplierCategoryID)
        INCLUDE (SupplierName, IsActive);

    CREATE NONCLUSTERED INDEX IX_Purchasing_SuppliersSecure_SupplierReference
        ON Purchasing.SuppliersSecure (SupplierReference)
        WHERE SupplierReference IS NOT NULL;
END;
GO

/* 2. Test data: 1,000 fake suppliers (plain T-SQL works, nothing is encrypted yet) */
IF NOT EXISTS (SELECT 1 FROM Purchasing.SuppliersSecure)
BEGIN
    DECLARE @CategoryCount int = (SELECT COUNT(*) FROM Purchasing.SupplierCategories);

    ;WITH cat AS
    (
        SELECT SupplierCategoryID,
               ROW_NUMBER() OVER (ORDER BY SupplierCategoryID) AS rn
        FROM Purchasing.SupplierCategories
    ),
    nums AS
    (
        SELECT TOP (1000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
        FROM sys.all_columns AS a
        CROSS JOIN sys.all_columns AS b
    )
    INSERT INTO Purchasing.SuppliersSecure
        (SupplierName, SupplierCategoryID, SupplierReference,
         BankAccountName, BankAccountBranch, BankAccountCode,
         BankAccountNumber, BankInternationalCode,
         PaymentDays, PhoneNumber, WebsiteURL,
         DeliveryAddressLine1, DeliveryPostalCode, IsActive)
    SELECT
        N'Secure Supplier ' + RIGHT(N'0000' + CAST(nums.n AS nvarchar(4)), 4) + N' Ltd',
        cat.SupplierCategoryID,
        N'SR' + RIGHT(N'00000' + CAST(nums.n AS nvarchar(5)), 5),

        /* every 25th supplier has no bank details, to test NULL handling */
        CASE WHEN nums.n % 25 = 0 THEN NULL
             ELSE N'Secure Supplier ' + RIGHT(N'0000' + CAST(nums.n AS nvarchar(4)), 4) END,
        CASE WHEN nums.n % 25 = 0 THEN NULL
             ELSE CHOOSE(CAST(nums.n % 5 AS int) + 1,
                         N'Lagos Main', N'Abuja Central', N'Port Harcourt',
                         N'Kano', N'Ibadan') END,
        CASE WHEN nums.n % 25 = 0 THEN NULL
             ELSE RIGHT(N'00000' + CAST(nums.n AS nvarchar(5)), 5) END,
        CASE WHEN nums.n % 25 = 0 THEN NULL
             ELSE RIGHT(REPLICATE(N'0', 10) +
                        CAST((nums.n * 1000003 + 123456789) % 10000000000 AS nvarchar(20)), 10) END,
        CASE WHEN nums.n % 25 = 0 THEN NULL
             ELSE N'TESTNG' + RIGHT(N'0000' + CAST(nums.n AS nvarchar(4)), 4) END,

        CHOOSE(CAST(nums.n % 5 AS int) + 1, 7, 14, 30, 45, 60),
        N'(234) 555-' + RIGHT(N'0000' + CAST(nums.n AS nvarchar(4)), 4),
        N'https://secure-supplier' + CAST(nums.n AS nvarchar(5)) + N'.example.com',
        CAST(nums.n AS nvarchar(5)) + N' Test Road',
        CAST(100000 + nums.n AS nvarchar(10)),
        CASE WHEN nums.n % 20 = 0 THEN 0 ELSE 1 END
    FROM nums
    JOIN cat ON cat.rn = ((nums.n - 1) % @CategoryCount) + 1;
END;
GO

/* 3. Sensitivity classifications (adding one overwrites any existing one) */
ADD SENSITIVITY CLASSIFICATION TO
    Purchasing.SuppliersSecure.BankAccountNumber,
    Purchasing.SuppliersSecure.BankAccountCode,
    Purchasing.SuppliersSecure.BankInternationalCode
WITH (
    LABEL = 'Highly Confidential',
    INFORMATION_TYPE = 'Financial'
);

ADD SENSITIVITY CLASSIFICATION TO
    Purchasing.SuppliersSecure.BankAccountName
WITH (
    LABEL = 'Confidential',
    INFORMATION_TYPE = 'Financial'
);

ADD SENSITIVITY CLASSIFICATION TO
    Purchasing.SuppliersSecure.PhoneNumber,
    Purchasing.SuppliersSecure.DeliveryAddressLine1,
    Purchasing.SuppliersSecure.DeliveryAddressLine2,
    Purchasing.SuppliersSecure.DeliveryPostalCode
WITH (
    LABEL = 'Confidential',
    INFORMATION_TYPE = 'Contact Info'
);

ADD SENSITIVITY CLASSIFICATION TO
    Purchasing.SuppliersSecure.CreatedBy
WITH (
    LABEL = 'Confidential',
    INFORMATION_TYPE = 'Organizational'
);
GO

/* 4. Verify: plaintext rows, before any encryption */
SELECT COUNT(*) AS SupplierRows,
       SUM(CASE WHEN BankAccountNumber IS NULL THEN 1 ELSE 0 END) AS RowsWithoutBankAccount
FROM Purchasing.SuppliersSecure;

SELECT TOP (5) SupplierID, SupplierName, BankAccountNumber, BankAccountName,
       BankAccountCode, BankInternationalCode
FROM Purchasing.SuppliersSecure
ORDER BY SupplierID;
GO
