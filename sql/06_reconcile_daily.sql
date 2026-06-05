USE OrderRecon;
GO

-- payment processor vs finance ledger by day and payment type.
-- @TolerancePct is a percent, so 0.01 means 0.01%.
-- with @RunID it persists to qa.DailyRecon and logs checks, without it just returns the rows
CREATE OR ALTER PROCEDURE qa.usp_ReconcileDaily
    @FromDate DATE,
    @ToDate DATE,
    @TolerancePct DECIMAL(9,4) = 0.01,
    @RunID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- TODO: move tolerance to a config table, finance wants it per payment type

    -- pad the utc range a day each side so the index is still usable,
    -- the real filter is on the local date further down
    DECLARE @FromUtc DATETIME2(0) = DATEADD(day, -1, CAST(@FromDate AS DATETIME2(0)));
    DECLARE @ToUtc DATETIME2(0) = DATEADD(day, 2, CAST(@ToDate AS DATETIME2(0)));
    DECLARE @ToExcl DATETIME2(0) = DATEADD(day, 1, CAST(@ToDate AS DATETIME2(0)));

    WITH pay_day AS (
        SELECT CAST(o.PurchasedAt AS DATE) AS BizDate, p.PaymentType,
            COUNT(*) AS Cnt, SUM(p.Amount) AS Amount
        FROM pay.Payment p
        JOIN oms.Orders o ON o.OrderID = p.OrderID
        WHERE o.PurchasedAt >= @FromDate
            AND o.PurchasedAt < @ToExcl
        GROUP BY CAST(o.PurchasedAt AS DATE), p.PaymentType
    ),
    fin_txn AS (
        -- finance posts in utc, olist is sao paulo local
        SELECT CAST(le.PostedDateUTC AT TIME ZONE 'UTC' AT TIME ZONE 'E. South America Standard Time' AS DATE) AS BizDate,
            le.PaymentType, le.Amount
        FROM fin.LedgerEntry le
        WHERE le.PostedDateUTC >= @FromUtc
            AND le.PostedDateUTC < @ToUtc
    ),
    fin_day AS (
        SELECT BizDate, PaymentType, COUNT(*) AS Cnt, SUM(Amount) AS Amount
        FROM fin_txn
        WHERE BizDate BETWEEN @FromDate AND @ToDate
        GROUP BY BizDate, PaymentType
    )
    SELECT COALESCE(pd.BizDate, fd.BizDate) AS ReconDate,
        COALESCE(pd.PaymentType, fd.PaymentType) AS PaymentType,
        ISNULL(pd.Cnt, 0) AS PayCount,
        ISNULL(fd.Cnt, 0) AS FinCount,
        ISNULL(pd.Amount, 0) AS PayAmount,
        ISNULL(fd.Amount, 0) AS FinAmount,
        IIF(pd.BizDate IS NULL OR fd.BizDate IS NULL, 1, 0) AS MissingSide
    INTO #recon
    FROM pay_day pd
    FULL OUTER JOIN fin_day fd
        ON fd.BizDate = pd.BizDate
        AND fd.PaymentType = pd.PaymentType;

    SELECT r.ReconDate, r.PaymentType, r.PayCount, r.FinCount, r.PayAmount, r.FinAmount,
        r.FinAmount - r.PayAmount AS AmountDiff,
        CAST(100.0 * (r.FinAmount - r.PayAmount) / NULLIF(r.PayAmount, 0) AS DECIMAL(9,4)) AS DiffPct,
        CASE
            WHEN r.MissingSide = 1 THEN 1
            -- counts have to match exactly, a small double post can hide inside the amount tolerance
            WHEN r.PayCount <> r.FinCount THEN 1
            WHEN ABS(r.FinAmount - r.PayAmount) > ABS(r.PayAmount) * @TolerancePct / 100 THEN 1
            ELSE 0
        END AS OverTolerance
    INTO #result
    FROM #recon r;

    IF @RunID IS NULL
    BEGIN
        SELECT ReconDate, PaymentType, PayCount, FinCount, PayAmount, FinAmount, AmountDiff, DiffPct, OverTolerance
        FROM #result
        ORDER BY ReconDate, PaymentType;
        RETURN;
    END

    INSERT INTO qa.DailyRecon (RunID, ReconDate, PaymentType, PayCount, FinCount, PayAmount, FinAmount, AmountDiff, DiffPct, OverTolerance)
    SELECT @RunID, ReconDate, PaymentType, PayCount, FinCount, PayAmount, FinAmount, AmountDiff, DiffPct, OverTolerance
    FROM #result;

    CREATE TABLE #hits (ID VARCHAR(100) NOT NULL);

    INSERT INTO #hits (ID)
    SELECT CONCAT(CONVERT(CHAR(10), ReconDate, 23), '/', PaymentType)
    FROM #result
    WHERE OverTolerance = 1;
    EXEC qa.usp_LogCheck @RunID, 'recon_daily_over_tolerance', 'HIGH';

    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT CONCAT(CONVERT(CHAR(10), r.ReconDate, 23), '/', r.PaymentType)
    FROM #recon r
    WHERE r.MissingSide = 1;
    EXEC qa.usp_LogCheck @RunID, 'recon_daily_missing_side', 'HIGH';
END
GO
