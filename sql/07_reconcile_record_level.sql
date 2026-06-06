USE OrderRecon;
GO

CREATE OR ALTER PROCEDURE qa.usp_ReconcileRecordLevel
    @RunID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- grain is one processor payment (order + sequence). fin is summed to that grain so a
    -- double post shows up as a changed amount instead of vanishing in EXCEPT's distinct
    CREATE TABLE #pay (
        OrderID CHAR(32) NOT NULL,
        PaymentSeq TINYINT NOT NULL,
        PaymentType VARCHAR(20) NOT NULL,
        Amount DECIMAL(14,2) NOT NULL,
        RowHash BINARY(32) NULL,
        PRIMARY KEY (OrderID, PaymentSeq)
    );
    CREATE TABLE #fin (
        OrderID CHAR(32) NOT NULL,
        PaymentSeq TINYINT NOT NULL,
        PaymentType VARCHAR(20) NOT NULL,
        Amount DECIMAL(14,2) NOT NULL,
        RowHash BINARY(32) NULL,
        PRIMARY KEY (OrderID, PaymentSeq)
    );

    INSERT INTO #pay (OrderID, PaymentSeq, PaymentType, Amount)
    SELECT p.OrderID, p.PaymentSeq, p.PaymentType, p.Amount
    FROM pay.Payment p;

    INSERT INTO #fin (OrderID, PaymentSeq, PaymentType, Amount)
    SELECT le.OrderID, le.PaymentSeq, MAX(le.PaymentType), SUM(le.Amount)
    FROM fin.LedgerEntry le
    GROUP BY le.OrderID, le.PaymentSeq;

    UPDATE #pay SET RowHash = HASHBYTES('SHA2_256', CONCAT_WS('|', PaymentType, Amount));
    UPDATE #fin SET RowHash = HASHBYTES('SHA2_256', CONCAT_WS('|', PaymentType, Amount));

    CREATE TABLE #diff (
        OrderID CHAR(32) NOT NULL,
        PaymentSeq TINYINT NOT NULL,
        DiffType VARCHAR(20) NOT NULL,
        PayAmount DECIMAL(14,2) NULL,
        FinAmount DECIMAL(14,2) NULL
    );

    INSERT INTO #diff (OrderID, PaymentSeq, DiffType, PayAmount)
    SELECT k.OrderID, k.PaymentSeq, 'MISSING_IN_FIN', p.Amount
    FROM (
        SELECT OrderID, PaymentSeq FROM #pay
        EXCEPT
        SELECT OrderID, PaymentSeq FROM #fin
    ) k
    JOIN #pay p ON p.OrderID = k.OrderID AND p.PaymentSeq = k.PaymentSeq;

    INSERT INTO #diff (OrderID, PaymentSeq, DiffType, FinAmount)
    SELECT k.OrderID, k.PaymentSeq, 'EXTRA_IN_FIN', f.Amount
    FROM (
        SELECT OrderID, PaymentSeq FROM #fin
        EXCEPT
        SELECT OrderID, PaymentSeq FROM #pay
    ) k
    JOIN #fin f ON f.OrderID = k.OrderID AND f.PaymentSeq = k.PaymentSeq;

    -- same key on both sides, compare a hash of the rest instead of column by column
    INSERT INTO #diff (OrderID, PaymentSeq, DiffType, PayAmount, FinAmount)
    SELECT p.OrderID, p.PaymentSeq, 'CHANGED', p.Amount, f.Amount
    FROM #pay p
    JOIN #fin f ON f.OrderID = p.OrderID AND f.PaymentSeq = p.PaymentSeq
    WHERE p.RowHash <> f.RowHash;

    IF @RunID IS NULL
    BEGIN
        SELECT OrderID, PaymentSeq, DiffType, PayAmount, FinAmount
        FROM #diff
        ORDER BY DiffType, OrderID, PaymentSeq;
        RETURN;
    END

    INSERT INTO qa.RecordDiff (RunID, OrderID, PaymentSeq, DiffType, PayAmount, FinAmount)
    SELECT @RunID, OrderID, PaymentSeq, DiffType, PayAmount, FinAmount
    FROM #diff;

    CREATE TABLE #hits (ID VARCHAR(100) NOT NULL);

    INSERT INTO #hits (ID)
    SELECT CONCAT(OrderID, '/', PaymentSeq) FROM #diff WHERE DiffType = 'MISSING_IN_FIN';
    EXEC qa.usp_LogCheck @RunID, 'recon_record_missing_in_fin', 'HIGH';

    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT CONCAT(OrderID, '/', PaymentSeq) FROM #diff WHERE DiffType = 'EXTRA_IN_FIN';
    EXEC qa.usp_LogCheck @RunID, 'recon_record_extra_in_fin', 'HIGH';

    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT CONCAT(OrderID, '/', PaymentSeq) FROM #diff WHERE DiffType = 'CHANGED';
    EXEC qa.usp_LogCheck @RunID, 'recon_record_amount_changed', 'HIGH';
END
GO
