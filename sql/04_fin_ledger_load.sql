USE OrderRecon;
GO

-- olist has no finance data, so this plays the finance system's nightly ingest:
-- one ledger row per processor payment, posted in utc
CREATE OR ALTER PROCEDURE etl.usp_LoadFinLedger
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;

    TRUNCATE TABLE fin.LedgerEntry;

    -- brazil still had DST in 2016-2018, AT TIME ZONE applies the historical rules
    INSERT INTO fin.LedgerEntry (OrderID, PaymentSeq, PaymentType, Amount, PostedDateUTC)
    SELECT p.OrderID, p.PaymentSeq, p.PaymentType, p.Amount,
        CAST(o.PurchasedAt AT TIME ZONE 'E. South America Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(0))
    FROM pay.Payment p
    JOIN oms.Orders o ON o.OrderID = p.OrderID
    ORDER BY o.PurchasedAt, p.OrderID, p.PaymentSeq;

    INSERT INTO etl.LoadAudit (TableName, SourceRows, LoadedRows)
    SELECT 'fin.LedgerEntry', (SELECT COUNT(*) FROM pay.Payment), (SELECT COUNT(*) FROM fin.LedgerEntry);

    COMMIT TRANSACTION;
END
GO

EXEC etl.usp_LoadFinLedger;

SELECT TableName, SourceRows, LoadedRows, Result
FROM etl.LoadAudit
WHERE TableName = 'fin.LedgerEntry';
GO
