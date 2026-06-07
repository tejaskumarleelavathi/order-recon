USE OrderRecon;
GO

CREATE SCHEMA stg;
GO

-- delta feed from the order platform. deletes only carry the key
CREATE TABLE stg.OrderUpdate (
    BatchID INT NOT NULL,
    OrderID CHAR(32) NOT NULL,
    ChangeType CHAR(1) NOT NULL CONSTRAINT CK_OrderUpdate_ChangeType CHECK (ChangeType IN ('I', 'U', 'D')),
    CustomerID CHAR(32) NULL,
    OrderStatus VARCHAR(15) NULL,
    PurchasedAt DATETIME2(0) NULL,
    ApprovedAt DATETIME2(0) NULL,
    DeliveredCarrierAt DATETIME2(0) NULL,
    DeliveredCustomerAt DATETIME2(0) NULL,
    EstimatedDeliveryDate DATE NULL,
    ExtractedAt DATETIME2(0) NOT NULL CONSTRAINT DF_OrderUpdate_ExtractedAt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_OrderUpdate PRIMARY KEY (BatchID, OrderID)
);

CREATE TABLE etl.OrderMergeLog (
    LogID INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_OrderMergeLog PRIMARY KEY,
    BatchID INT NOT NULL,
    MergeAction VARCHAR(10) NOT NULL,
    OrderID CHAR(32) NOT NULL,
    OldStatus VARCHAR(15) NULL,
    NewStatus VARCHAR(15) NULL,
    LoggedAt DATETIME2(0) NOT NULL CONSTRAINT DF_OrderMergeLog_LoggedAt DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_OrderMergeLog_BatchID ON etl.OrderMergeLog (BatchID);
GO

CREATE OR ALTER PROCEDURE etl.usp_ApplyOrderUpdates
    @BatchID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF EXISTS (SELECT 1 FROM etl.OrderMergeLog WHERE BatchID = @BatchID)
        THROW 50001, 'batch already applied', 1;

    DECLARE @msg NVARCHAR(2048);

    BEGIN TRY
        BEGIN TRANSACTION;

        -- oms FKs don't cascade, clear children of deleted orders first
        DELETE oi
        FROM oms.OrderItem oi
        JOIN stg.OrderUpdate s ON s.OrderID = oi.OrderID
        WHERE s.BatchID = @BatchID AND s.ChangeType = 'D';

        DELETE r
        FROM oms.Review r
        JOIN stg.OrderUpdate s ON s.OrderID = r.OrderID
        WHERE s.BatchID = @BatchID AND s.ChangeType = 'D';

        -- TODO: new orders arrive without items, the item feed isn't wired up yet
        MERGE oms.Orders AS t
        USING (
            SELECT OrderID, ChangeType, CustomerID, OrderStatus, PurchasedAt, ApprovedAt,
                DeliveredCarrierAt, DeliveredCustomerAt, EstimatedDeliveryDate
            FROM stg.OrderUpdate
            WHERE BatchID = @BatchID
        ) AS s
            ON t.OrderID = s.OrderID
        WHEN MATCHED AND s.ChangeType = 'D' THEN
            DELETE
        -- EXCEPT handles the NULL compares and skips rows that didn't really change
        WHEN MATCHED AND s.ChangeType = 'U' AND EXISTS (
                SELECT s.CustomerID, s.OrderStatus, s.PurchasedAt, s.ApprovedAt, s.DeliveredCarrierAt, s.DeliveredCustomerAt, s.EstimatedDeliveryDate
                EXCEPT
                SELECT t.CustomerID, t.OrderStatus, t.PurchasedAt, t.ApprovedAt, t.DeliveredCarrierAt, t.DeliveredCustomerAt, t.EstimatedDeliveryDate
            ) THEN
            UPDATE SET
                CustomerID = s.CustomerID,
                OrderStatus = s.OrderStatus,
                PurchasedAt = s.PurchasedAt,
                ApprovedAt = s.ApprovedAt,
                DeliveredCarrierAt = s.DeliveredCarrierAt,
                DeliveredCustomerAt = s.DeliveredCustomerAt,
                EstimatedDeliveryDate = s.EstimatedDeliveryDate,
                ModifiedAt = SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET AND s.ChangeType = 'I' THEN
            INSERT (OrderID, CustomerID, OrderStatus, PurchasedAt, ApprovedAt, DeliveredCarrierAt, DeliveredCustomerAt, EstimatedDeliveryDate)
            VALUES (s.OrderID, s.CustomerID, s.OrderStatus, s.PurchasedAt, s.ApprovedAt, s.DeliveredCarrierAt, s.DeliveredCustomerAt, s.EstimatedDeliveryDate)
        -- no WHEN NOT MATCHED BY SOURCE, staging is a delta not a full snapshot
        OUTPUT @BatchID, $action, COALESCE(inserted.OrderID, deleted.OrderID), deleted.OrderStatus, inserted.OrderStatus
        INTO etl.OrderMergeLog (BatchID, MergeAction, OrderID, OldStatus, NewStatus);

        -- every staged row should produce exactly one action. an I for an existing order,
        -- a U/D for a missing one, or a U with nothing changed all show up as a mismatch
        WITH expected AS (
            SELECT CASE ChangeType WHEN 'I' THEN 'INSERT' WHEN 'U' THEN 'UPDATE' ELSE 'DELETE' END AS MergeAction,
                COUNT(*) AS Cnt
            FROM stg.OrderUpdate
            WHERE BatchID = @BatchID
            GROUP BY ChangeType
        ),
        actual AS (
            SELECT MergeAction, COUNT(*) AS Cnt
            FROM etl.OrderMergeLog
            WHERE BatchID = @BatchID
            GROUP BY MergeAction
        )
        SELECT COALESCE(e.MergeAction, a.MergeAction) AS MergeAction,
            ISNULL(e.Cnt, 0) AS Staged,
            ISNULL(a.Cnt, 0) AS Applied,
            IIF(ISNULL(e.Cnt, 0) = ISNULL(a.Cnt, 0), 'OK', 'MISMATCH') AS Result
        INTO #check
        FROM expected e
        FULL OUTER JOIN actual a ON a.MergeAction = e.MergeAction;

        IF EXISTS (SELECT 1 FROM #check WHERE Result = 'MISMATCH')
        BEGIN
            SELECT @msg = CONCAT('batch ', @BatchID, ' rolled back, staged vs applied: ',
                STRING_AGG(CONCAT(MergeAction, ' ', Staged, '/', Applied), ', '))
            FROM #check;
            THROW 50002, @msg, 1;
        END

        COMMIT TRANSACTION;

        SELECT MergeAction, Staged, Applied, Result
        FROM #check
        ORDER BY MergeAction;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

SET NOCOUNT ON;

-- batch 1: 20 shipped orders now delivered, 10 new orders, 5 unavailable orders purged upstream
DECLARE @BatchID INT = 1;

INSERT INTO stg.OrderUpdate (BatchID, OrderID, ChangeType, CustomerID, OrderStatus, PurchasedAt, ApprovedAt,
    DeliveredCarrierAt, DeliveredCustomerAt, EstimatedDeliveryDate)
SELECT TOP (20) @BatchID, o.OrderID, 'U', o.CustomerID, 'delivered', o.PurchasedAt, o.ApprovedAt,
    o.DeliveredCarrierAt, DATEADD(day, 6, o.DeliveredCarrierAt), o.EstimatedDeliveryDate
FROM oms.Orders o
WHERE o.OrderStatus = 'shipped'
    AND o.DeliveredCarrierAt IS NOT NULL
ORDER BY o.PurchasedAt DESC;

-- olist ids are 32 char lowercase hex, md5 gives the same shape
INSERT INTO stg.OrderUpdate (BatchID, OrderID, ChangeType, CustomerID, OrderStatus, PurchasedAt, EstimatedDeliveryDate)
SELECT @BatchID, LOWER(CONVERT(CHAR(32), HASHBYTES('MD5', CONCAT('new-order-', c.rn)), 2)), 'I',
    c.CustomerID, 'created', DATEADD(minute, c.rn * 11, CAST('2018-10-18T09:00:00' AS DATETIME2(0))), '2018-11-05'
FROM (
    SELECT TOP (10) cu.CustomerID, ROW_NUMBER() OVER (ORDER BY cu.CustomerID) AS rn
    FROM oms.Customer cu
    ORDER BY cu.CustomerID
) c;

INSERT INTO stg.OrderUpdate (BatchID, OrderID, ChangeType)
SELECT TOP (5) @BatchID, o.OrderID, 'D'
FROM oms.Orders o
WHERE o.OrderStatus = 'unavailable'
    AND NOT EXISTS (SELECT 1 FROM oms.OrderItem oi WHERE oi.OrderID = o.OrderID)
ORDER BY o.PurchasedAt;

SELECT ChangeType, COUNT(*) AS StagedRows
FROM stg.OrderUpdate
WHERE BatchID = @BatchID
GROUP BY ChangeType;
GO
