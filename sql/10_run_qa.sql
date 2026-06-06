USE OrderRecon;
GO
SET NOCOUNT ON;

DECLARE @RunID INT;
EXEC qa.usp_RunAll @RunID = @RunID OUTPUT;

SELECT r.CheckName, r.Severity, r.RowsFlagged, IIF(r.Passed = 1, 'PASS', 'FAIL') AS Result,
    LEFT(r.SampleIDs, 70) AS SampleIDs
FROM qa.ValidationResult r
WHERE r.RunID = @RunID
ORDER BY r.ValidationResultID;

-- worst daily cells
SELECT TOP (10) d.ReconDate, d.PaymentType, d.PayCount, d.FinCount, d.PayAmount, d.FinAmount, d.AmountDiff
FROM qa.DailyRecon d
WHERE d.RunID = @RunID
    AND d.OverTolerance = 1
ORDER BY ABS(d.AmountDiff) DESC;

SELECT d.DiffType, COUNT(*) AS Records,
    SUM(ISNULL(d.FinAmount, 0) - ISNULL(d.PayAmount, 0)) AS FinMinusPay
FROM qa.RecordDiff d
WHERE d.RunID = @RunID
GROUP BY d.DiffType
ORDER BY d.DiffType;
GO
