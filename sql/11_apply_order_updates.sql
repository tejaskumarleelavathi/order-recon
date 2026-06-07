USE OrderRecon;
GO
SET NOCOUNT ON;

EXEC etl.usp_ApplyOrderUpdates @BatchID = 1;

-- spot check the target against staging after the merge
SELECT
    SUM(IIF(s.ChangeType = 'I' AND o.OrderID IS NOT NULL, 1, 0)) AS InsertedPresent,
    SUM(IIF(s.ChangeType = 'U' AND o.OrderStatus = s.OrderStatus AND o.DeliveredCustomerAt = s.DeliveredCustomerAt, 1, 0)) AS UpdatedMatching,
    SUM(IIF(s.ChangeType = 'D' AND o.OrderID IS NULL, 1, 0)) AS DeletedGone
FROM stg.OrderUpdate s
LEFT JOIN oms.Orders o ON o.OrderID = s.OrderID
WHERE s.BatchID = 1;

SELECT OrderStatus, COUNT(*) AS Orders
FROM oms.Orders
GROUP BY OrderStatus
ORDER BY Orders DESC;
GO
