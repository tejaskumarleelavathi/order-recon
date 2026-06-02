USE OrderRecon;
GO

CREATE SCHEMA oms;
GO
CREATE SCHEMA pay;
GO
CREATE SCHEMA ref;
GO
CREATE SCHEMA fin;
GO
CREATE SCHEMA qa;
GO
CREATE SCHEMA etl;
GO

-- oms = olist order platform, pay = payment processor, fin = finance ledger we build in 04.
-- no FKs across those on purpose, orphans between systems are what the checks look for.
-- all olist timestamps are sao paulo local time.

CREATE TABLE ref.CategoryTranslation (
    CategoryName VARCHAR(60) NOT NULL CONSTRAINT PK_CategoryTranslation PRIMARY KEY,
    CategoryNameEnglish VARCHAR(60) NOT NULL
);

-- no PK on purpose, the source has a quarter million exact duplicate rows
CREATE TABLE ref.Geolocation (
    GeoRowID INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Geolocation PRIMARY KEY,
    ZipPrefix CHAR(5) NOT NULL,
    Lat FLOAT NOT NULL,
    Lng FLOAT NOT NULL,
    City NVARCHAR(60) NOT NULL,
    State CHAR(2) NOT NULL
);
CREATE INDEX IX_Geolocation_Zip ON ref.Geolocation (ZipPrefix);

-- CustomerID is per order in olist, CustomerUniqueID is the actual person
CREATE TABLE oms.Customer (
    CustomerID CHAR(32) NOT NULL CONSTRAINT PK_Customer PRIMARY KEY,
    CustomerUniqueID CHAR(32) NOT NULL,
    ZipPrefix CHAR(5) NOT NULL,
    City NVARCHAR(60) NOT NULL,
    State CHAR(2) NOT NULL
);

CREATE TABLE oms.Seller (
    SellerID CHAR(32) NOT NULL CONSTRAINT PK_Seller PRIMARY KEY,
    ZipPrefix CHAR(5) NOT NULL,
    City NVARCHAR(60) NOT NULL,
    State CHAR(2) NOT NULL
);

-- no FK to ref.CategoryTranslation, two real categories have no translation and the load would reject them
CREATE TABLE oms.Product (
    ProductID CHAR(32) NOT NULL CONSTRAINT PK_Product PRIMARY KEY,
    CategoryName VARCHAR(60) NULL,
    NameLength SMALLINT NULL,
    DescriptionLength SMALLINT NULL,
    PhotosQty TINYINT NULL,
    WeightG INT NULL,
    LengthCm SMALLINT NULL,
    HeightCm SMALLINT NULL,
    WidthCm SMALLINT NULL
);

CREATE TABLE oms.Orders (
    OrderID CHAR(32) NOT NULL CONSTRAINT PK_Orders PRIMARY KEY,
    CustomerID CHAR(32) NOT NULL CONSTRAINT FK_Orders_Customer REFERENCES oms.Customer (CustomerID),
    OrderStatus VARCHAR(15) NOT NULL,
    PurchasedAt DATETIME2(0) NOT NULL,
    ApprovedAt DATETIME2(0) NULL,
    DeliveredCarrierAt DATETIME2(0) NULL,
    DeliveredCustomerAt DATETIME2(0) NULL,
    EstimatedDeliveryDate DATE NULL,
    ModifiedAt DATETIME2(0) NOT NULL CONSTRAINT DF_Orders_ModifiedAt DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_Orders_PurchasedAt ON oms.Orders (PurchasedAt) INCLUDE (OrderStatus);

CREATE TABLE oms.OrderItem (
    OrderID CHAR(32) NOT NULL CONSTRAINT FK_OrderItem_Orders REFERENCES oms.Orders (OrderID),
    OrderItemID TINYINT NOT NULL,
    ProductID CHAR(32) NOT NULL CONSTRAINT FK_OrderItem_Product REFERENCES oms.Product (ProductID),
    SellerID CHAR(32) NOT NULL CONSTRAINT FK_OrderItem_Seller REFERENCES oms.Seller (SellerID),
    ShippingLimitAt DATETIME2(0) NOT NULL,
    Price DECIMAL(12,2) NOT NULL,
    FreightValue DECIMAL(12,2) NOT NULL,
    CONSTRAINT PK_OrderItem PRIMARY KEY (OrderID, OrderItemID)
);

-- review_id isn't unique in the source (same review attached to several orders), so the key is both
CREATE TABLE oms.Review (
    ReviewID CHAR(32) NOT NULL,
    OrderID CHAR(32) NOT NULL CONSTRAINT FK_Review_Orders REFERENCES oms.Orders (OrderID),
    Score TINYINT NOT NULL CONSTRAINT CK_Review_Score CHECK (Score BETWEEN 1 AND 5),
    CommentTitle NVARCHAR(100) NULL,
    CommentMessage NVARCHAR(1000) NULL,
    CreatedDate DATE NOT NULL,
    AnsweredAt DATETIME2(0) NOT NULL,
    CONSTRAINT PK_Review PRIMARY KEY (ReviewID, OrderID)
);
CREATE INDEX IX_Review_OrderID ON oms.Review (OrderID);

CREATE TABLE pay.Payment (
    OrderID CHAR(32) NOT NULL,
    PaymentSeq TINYINT NOT NULL,
    PaymentType VARCHAR(20) NOT NULL,
    Installments TINYINT NOT NULL,
    Amount DECIMAL(12,2) NOT NULL,
    CONSTRAINT PK_Payment PRIMARY KEY (OrderID, PaymentSeq)
);

CREATE TABLE fin.LedgerEntry (
    LedgerEntryID BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LedgerEntry PRIMARY KEY,
    OrderID CHAR(32) NOT NULL,
    PaymentSeq TINYINT NOT NULL,
    PaymentType VARCHAR(20) NOT NULL,
    Amount DECIMAL(12,2) NOT NULL,
    PostedDateUTC DATETIME2(0) NOT NULL
);
CREATE INDEX IX_LedgerEntry_Order ON fin.LedgerEntry (OrderID, PaymentSeq) INCLUDE (PaymentType, Amount);
CREATE INDEX IX_LedgerEntry_Posted ON fin.LedgerEntry (PostedDateUTC) INCLUDE (PaymentType, Amount);

CREATE TABLE etl.LoadAudit (
    LoadAuditID INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LoadAudit PRIMARY KEY,
    TableName VARCHAR(50) NOT NULL,
    SourceRows INT NOT NULL,
    LoadedRows INT NOT NULL,
    Result AS IIF(SourceRows = LoadedRows, 'OK', 'MISMATCH'),
    LoadedAt DATETIME2(0) NOT NULL CONSTRAINT DF_LoadAudit_LoadedAt DEFAULT SYSUTCDATETIME()
);

CREATE TABLE qa.ValidationRun (
    RunID INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ValidationRun PRIMARY KEY,
    StartedAt DATETIME2(0) NOT NULL CONSTRAINT DF_ValidationRun_StartedAt DEFAULT SYSUTCDATETIME(),
    FinishedAt DATETIME2(0) NULL,
    Status VARCHAR(10) NOT NULL CONSTRAINT DF_ValidationRun_Status DEFAULT 'RUNNING',
    ErrorNumber INT NULL,
    ErrorMessage NVARCHAR(4000) NULL
);

CREATE TABLE qa.ValidationResult (
    ValidationResultID INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ValidationResult PRIMARY KEY,
    RunID INT NOT NULL CONSTRAINT FK_ValidationResult_Run REFERENCES qa.ValidationRun (RunID),
    CheckName VARCHAR(50) NOT NULL,
    Severity VARCHAR(10) NOT NULL CONSTRAINT CK_ValidationResult_Severity CHECK (Severity IN ('HIGH', 'MEDIUM', 'LOW')),
    RowsFlagged INT NOT NULL,
    SampleIDs VARCHAR(500) NULL,
    Passed BIT NOT NULL,
    CheckedAt DATETIME2(0) NOT NULL CONSTRAINT DF_ValidationResult_CheckedAt DEFAULT SYSUTCDATETIME()
);

CREATE TABLE qa.DailyRecon (
    RunID INT NOT NULL CONSTRAINT FK_DailyRecon_Run REFERENCES qa.ValidationRun (RunID),
    ReconDate DATE NOT NULL,
    PaymentType VARCHAR(20) NOT NULL,
    PayCount INT NOT NULL,
    FinCount INT NOT NULL,
    PayAmount DECIMAL(14,2) NOT NULL,
    FinAmount DECIMAL(14,2) NOT NULL,
    AmountDiff DECIMAL(14,2) NOT NULL,
    DiffPct DECIMAL(9,4) NULL,
    OverTolerance BIT NOT NULL,
    CONSTRAINT PK_DailyRecon PRIMARY KEY (RunID, ReconDate, PaymentType)
);

CREATE TABLE qa.RecordDiff (
    RunID INT NOT NULL CONSTRAINT FK_RecordDiff_Run REFERENCES qa.ValidationRun (RunID),
    OrderID CHAR(32) NOT NULL,
    PaymentSeq TINYINT NOT NULL,
    DiffType VARCHAR(20) NOT NULL,
    PayAmount DECIMAL(14,2) NULL,
    FinAmount DECIMAL(14,2) NULL,
    CONSTRAINT PK_RecordDiff PRIMARY KEY (RunID, OrderID, PaymentSeq)
);
GO
