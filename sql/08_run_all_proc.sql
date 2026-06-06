USE OrderRecon;
GO

CREATE OR ALTER PROCEDURE qa.usp_RunAll
    @FromDate DATE = '2016-09-01',
    @ToDate DATE = '2018-10-31',
    @TolerancePct DECIMAL(9,4) = 0.01,
    @RunID INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- run row goes in outside the transaction so a failed run still leaves a record
    INSERT INTO qa.ValidationRun (Status) VALUES ('RUNNING');
    SET @RunID = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC qa.usp_RunDataQualityChecks @RunID = @RunID;
        EXEC qa.usp_ReconcileDaily @FromDate = @FromDate, @ToDate = @ToDate, @TolerancePct = @TolerancePct, @RunID = @RunID;
        EXEC qa.usp_ReconcileRecordLevel @RunID = @RunID;

        COMMIT TRANSACTION;

        UPDATE qa.ValidationRun
        SET Status = 'DONE', FinishedAt = SYSUTCDATETIME()
        WHERE RunID = @RunID;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        UPDATE qa.ValidationRun
        SET Status = 'FAILED',
            FinishedAt = SYSUTCDATETIME(),
            ErrorNumber = ERROR_NUMBER(),
            ErrorMessage = CONCAT(ERROR_PROCEDURE(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE())
        WHERE RunID = @RunID;

        THROW;
    END CATCH

    DECLARE @total INT, @failed INT, @high INT, @medium INT, @low INT, @detail VARCHAR(MAX);

    SELECT @total = COUNT(*),
        @failed = SUM(IIF(r.Passed = 0, 1, 0)),
        @high = SUM(IIF(r.Passed = 0 AND r.Severity = 'HIGH', 1, 0)),
        @medium = SUM(IIF(r.Passed = 0 AND r.Severity = 'MEDIUM', 1, 0)),
        @low = SUM(IIF(r.Passed = 0 AND r.Severity = 'LOW', 1, 0))
    FROM qa.ValidationResult r
    WHERE r.RunID = @RunID;

    -- only the HIGH failures, sqlcmd cuts long PRINTs off around 1000 chars.
    -- the full list is in qa.ValidationResult
    SELECT @detail = STRING_AGG(CAST(CONCAT('  ', r.CheckName, ' (', r.RowsFlagged, ')') AS VARCHAR(MAX)), CHAR(10))
        WITHIN GROUP (ORDER BY r.ValidationResultID)
    FROM qa.ValidationResult r
    WHERE r.RunID = @RunID
        AND r.Passed = 0
        AND r.Severity = 'HIGH';

    PRINT CONCAT('run ', @RunID, ': ', @total, ' checks, ', @failed, ' failed (high ', @high, ', medium ', @medium, ', low ', @low, ')');
    PRINT 'high failures:';
    PRINT @detail;
END
GO
