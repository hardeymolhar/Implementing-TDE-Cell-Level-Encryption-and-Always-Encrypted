/* ============================================================
   Purchasing.Suppliers: production-grade table for Azure SQL DB / SQL Server
   Loaded with 500 fake supplier rows for testing.
   Built so this later works unchanged:
     ALTER TABLE Purchasing.Suppliers ADD BankAccountNumberEnc varbinary(256) NULL;
   Run in the target user database (not master).
   ============================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;   -- required for the filtered index; ODBC sqlcmd defaults it to OFF
GO

/* 1. Schema */
IF SCHEMA_ID(N'Purchasing') IS NULL
    EXEC (N'CREATE SCHEMA Purchasing AUTHORIZATION dbo;');
GO

/* 2. Lookup table referenced by Suppliers */
IF OBJECT_ID(N'Purchasing.SupplierCategories', N'U') IS NULL
BEGIN
    CREATE TABLE Purchasing.SupplierCategories
    (
        SupplierCategoryID   int IDENTITY(1,1) NOT NULL,
        SupplierCategoryName nvarchar(50)      NOT NULL,
        CONSTRAINT PK_Purchasing_SupplierCategories
            PRIMARY KEY CLUSTERED (SupplierCategoryID),
        CONSTRAINT UQ_Purchasing_SupplierCategories_Name
            UNIQUE (SupplierCategoryName)
    );
END;
GO

/* 3. Suppliers (system-versioned temporal table for audit history) */
IF OBJECT_ID(N'Purchasing.Suppliers', N'U') IS NULL
BEGIN
    CREATE TABLE Purchasing.Suppliers
    (
        SupplierID            int IDENTITY(1,1) NOT NULL,
        SupplierName          nvarchar(100)     NOT NULL,
        SupplierCategoryID    int               NOT NULL,
        SupplierReference     nvarchar(20)      NULL,

        /* Bank details: BankAccountNumber is the column cell-level encryption will protect */
        BankAccountName       nvarchar(50)      NULL,
        BankAccountBranch     nvarchar(50)      NULL,
        BankAccountCode       nvarchar(20)      NULL,
        BankAccountNumber     nvarchar(20)      NULL,
        BankInternationalCode nvarchar(20)      NULL,

        PaymentDays           int               NOT NULL
            CONSTRAINT DF_Purchasing_Suppliers_PaymentDays DEFAULT (30),
        InternalComments      nvarchar(max)     NULL,
        PhoneNumber           nvarchar(20)      NULL,
        WebsiteURL            nvarchar(256)     NULL,
        DeliveryAddressLine1  nvarchar(60)      NOT NULL,
        DeliveryAddressLine2  nvarchar(60)      NULL,
        DeliveryPostalCode    nvarchar(10)      NOT NULL,

        IsActive              bit               NOT NULL
            CONSTRAINT DF_Purchasing_Suppliers_IsActive DEFAULT (1),
        CreatedAtUtc          datetime2(3)      NOT NULL
            CONSTRAINT DF_Purchasing_Suppliers_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy             nvarchar(128)     NOT NULL
            CONSTRAINT DF_Purchasing_Suppliers_CreatedBy DEFAULT (SUSER_SNAME()),

        /* Temporal period columns (hidden, so SELECT * and inserts are unaffected) */
        ValidFrom datetime2(7) GENERATED ALWAYS AS ROW START HIDDEN NOT NULL,
        ValidTo   datetime2(7) GENERATED ALWAYS AS ROW END   HIDDEN NOT NULL,
        PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo),

        CONSTRAINT PK_Purchasing_Suppliers
            PRIMARY KEY CLUSTERED (SupplierID),
        CONSTRAINT UQ_Purchasing_Suppliers_SupplierName
            UNIQUE (SupplierName),
        CONSTRAINT FK_Purchasing_Suppliers_SupplierCategories
            FOREIGN KEY (SupplierCategoryID)
            REFERENCES Purchasing.SupplierCategories (SupplierCategoryID),
        CONSTRAINT CK_Purchasing_Suppliers_PaymentDays
            CHECK (PaymentDays BETWEEN 0 AND 365),
        CONSTRAINT CK_Purchasing_Suppliers_Name_NotBlank
            CHECK (LEN(LTRIM(RTRIM(SupplierName))) > 0)
    )
    WITH
    (
        SYSTEM_VERSIONING = ON
        (
            HISTORY_TABLE = Purchasing.Suppliers_Archive,
            HISTORY_RETENTION_PERIOD = 12 MONTHS
        )
    );

    /* Supports the foreign key and category lookups */
    CREATE NONCLUSTERED INDEX IX_Purchasing_Suppliers_SupplierCategoryID
        ON Purchasing.Suppliers (SupplierCategoryID)
        INCLUDE (SupplierName, IsActive);

    CREATE NONCLUSTERED INDEX IX_Purchasing_Suppliers_SupplierReference
        ON Purchasing.Suppliers (SupplierReference)
        WHERE SupplierReference IS NOT NULL;
END;
GO

/* 4. Test data: 500 fake suppliers (remove before production use) */

/* Categories: add any that are missing */
INSERT INTO Purchasing.SupplierCategories (SupplierCategoryName)
SELECT v.SupplierCategoryName
FROM (VALUES
        (N'Novelty Goods Supplier'), (N'Packaging Supplier'), (N'Logistics Supplier'),
        (N'Food and Beverage Supplier'), (N'Industrial Supplier'), (N'Textile Supplier'),
        (N'Electronics Supplier'), (N'Agricultural Supplier')
     ) AS v (SupplierCategoryName)
WHERE NOT EXISTS (SELECT 1 FROM Purchasing.SupplierCategories c
                  WHERE c.SupplierCategoryName = v.SupplierCategoryName);
GO

/* Remove the 3 rows from the earlier version of this script, if present */
DELETE FROM Purchasing.Suppliers WHERE SupplierName LIKE N'Test Supplier %';
GO

IF NOT EXISTS (SELECT 1 FROM Purchasing.Suppliers)
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
        SELECT TOP (500) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
        FROM sys.all_columns AS a
        CROSS JOIN sys.all_columns AS b
    )
    INSERT INTO Purchasing.Suppliers
        (SupplierName, SupplierCategoryID, SupplierReference,
         BankAccountName, BankAccountBranch, BankAccountCode,
         BankAccountNumber, BankInternationalCode,
         PaymentDays, PhoneNumber, WebsiteURL,
         DeliveryAddressLine1, DeliveryPostalCode, IsActive)
    SELECT
        /* unique name: Supplier 0001 Trading Co, Supplier 0002 Logistics Ltd, ... */
        N'Supplier ' + RIGHT(N'0000' + CAST(nums.n AS nvarchar(4)), 4) + N' ' +
            CHOOSE(CAST(nums.n % 10 AS int) + 1,
                   N'Trading Co', N'Logistics Ltd', N'Packaging Ltd', N'Foods Ltd',
                   N'Industrial Supplies', N'Textiles Ltd', N'Electronics Ltd',
                   N'Distribution Ltd', N'Agro Ltd', N'Chemicals Ltd'),
        cat.SupplierCategoryID,
        N'SR' + RIGHT(N'00000' + CAST(nums.n AS nvarchar(5)), 5),

        /* every 25th supplier has no bank details, to test NULL handling */
        CASE WHEN nums.n % 25 = 0 THEN NULL
             ELSE N'Supplier ' + RIGHT(N'0000' + CAST(nums.n AS nvarchar(4)), 4) END,
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
             ELSE N'TESTNG' + RIGHT(N'000' + CAST(nums.n AS nvarchar(3)), 3) END,

        CHOOSE(CAST(nums.n % 5 AS int) + 1, 7, 14, 30, 45, 60),
        N'(234) 555-' + RIGHT(N'0000' + CAST(nums.n AS nvarchar(4)), 4),
        N'https://supplier' + CAST(nums.n AS nvarchar(5)) + N'.example.com',
        CAST(nums.n AS nvarchar(5)) + N' Test Road',
        CAST(100000 + nums.n AS nvarchar(10)),
        CASE WHEN nums.n % 20 = 0 THEN 0 ELSE 1 END
    FROM nums
    JOIN cat ON cat.rn = ((nums.n - 1) % @CategoryCount) + 1;
END;
GO

/* 5. Verify */
SELECT COUNT(*) AS SupplierRows,
       SUM(CASE WHEN BankAccountNumber IS NULL THEN 1 ELSE 0 END) AS RowsWithoutBankAccount
FROM Purchasing.Suppliers;

SELECT TOP (5) SupplierID, SupplierName, BankAccountNumber
FROM Purchasing.Suppliers ORDER BY SupplierID;

SELECT name, temporal_type_desc FROM sys.tables WHERE schema_id = SCHEMA_ID(N'Purchasing');
GO