USE OrderRecon;
GO

-- shared by the qa procs. caller fills #hits with the offending ids, this writes one result row
CREATE OR ALTER PROCEDURE qa.usp_LogCheck
    @RunID INT,
    @CheckName VARCHAR(50),
    @Severity VARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO qa.ValidationResult (RunID, CheckName, Severity, RowsFlagged, SampleIDs, Passed)
    SELECT @RunID,
        @CheckName,
        @Severity,
        COUNT(*),
        STRING_AGG(IIF(h.rn <= 10, h.ID, NULL), ',') WITHIN GROUP (ORDER BY h.rn),
        IIF(COUNT(*) = 0, 1, 0)
    FROM (
        -- LEN first so numeric ids sort like numbers
        SELECT ID, ROW_NUMBER() OVER (ORDER BY LEN(ID), ID) AS rn
        FROM #hits
    ) h;
END
GO

CREATE OR ALTER PROCEDURE qa.usp_RunDataQualityChecks
    @RunID INT
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #hits (ID VARCHAR(100) NOT NULL);

    -- canceled/unavailable orders legitimately have no items, the rest shouldn't exist
    INSERT INTO #hits (ID)
    SELECT o.OrderID
    FROM oms.Orders o
    LEFT JOIN oms.OrderItem oi ON oi.OrderID = o.OrderID
    WHERE oi.OrderID IS NULL
        AND o.OrderStatus NOT IN ('canceled', 'unavailable');
    EXEC qa.usp_LogCheck @RunID, 'oms_order_without_items', 'HIGH';

    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT o.OrderID
    FROM oms.Orders o
    LEFT JOIN pay.Payment p ON p.OrderID = o.OrderID
    WHERE p.OrderID IS NULL;
    EXEC qa.usp_LogCheck @RunID, 'pay_order_without_payment', 'HIGH';

    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT o.OrderID
    FROM oms.Orders o
    WHERE o.OrderStatus = 'delivered'
        AND o.DeliveredCustomerAt IS NULL;
    EXEC qa.usp_LogCheck @RunID, 'oms_delivered_without_delivery_date', 'HIGH';

    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT o.OrderID
    FROM oms.Orders o
    WHERE o.OrderStatus = 'canceled'
        AND o.DeliveredCustomerAt IS NOT NULL;
    EXEC qa.usp_LogCheck @RunID, 'oms_canceled_but_delivered', 'MEDIUM';

    -- most of these are handed to the carrier before the payment approval timestamp,
    -- likely boleto approvals landing late. still worth knowing the size of it
    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT o.OrderID
    FROM oms.Orders o
    WHERE o.DeliveredCarrierAt < o.PurchasedAt
        OR o.DeliveredCarrierAt < o.ApprovedAt
        OR o.DeliveredCustomerAt < o.DeliveredCarrierAt;
    EXEC qa.usp_LogCheck @RunID, 'oms_order_timeline_out_of_order', 'LOW';

    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT CONCAT(p.OrderID, '/', p.PaymentSeq)
    FROM pay.Payment p
    WHERE p.Installments = 0;
    EXEC qa.usp_LogCheck @RunID, 'pay_zero_installments', 'LOW';

    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT CONCAT(p.OrderID, '/', p.PaymentSeq)
    FROM pay.Payment p
    WHERE p.PaymentType = 'not_defined';
    EXEC qa.usp_LogCheck @RunID, 'pay_type_not_defined', 'MEDIUM';

    -- paid more than items + freight is mostly card installment interest,
    -- paid less is the one that should worry someone
    TRUNCATE TABLE #hits;
    WITH items AS (
        SELECT oi.OrderID, SUM(oi.Price + oi.FreightValue) AS Amount
        FROM oms.OrderItem oi
        GROUP BY oi.OrderID
    ),
    paid AS (
        SELECT p.OrderID, SUM(p.Amount) AS Amount
        FROM pay.Payment p
        GROUP BY p.OrderID
    )
    INSERT INTO #hits (ID)
    SELECT i.OrderID
    FROM items i
    JOIN paid pd ON pd.OrderID = i.OrderID
    WHERE ABS(pd.Amount - i.Amount) > 1.00;
    EXEC qa.usp_LogCheck @RunID, 'pay_total_vs_items_over_1brl', 'MEDIUM';

    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT r.ReviewID
    FROM oms.Review r
    GROUP BY r.ReviewID
    HAVING COUNT(DISTINCT r.OrderID) > 1;
    EXEC qa.usp_LogCheck @RunID, 'oms_review_id_on_many_orders', 'MEDIUM';

    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT r.OrderID
    FROM oms.Review r
    GROUP BY r.OrderID
    HAVING COUNT(*) > 1;
    EXEC qa.usp_LogCheck @RunID, 'oms_order_with_many_reviews', 'LOW';

    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT p.ProductID
    FROM oms.Product p
    WHERE p.CategoryName IS NULL;
    EXEC qa.usp_LogCheck @RunID, 'oms_product_without_category', 'LOW';

    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT DISTINCT p.CategoryName
    FROM oms.Product p
    LEFT JOIN ref.CategoryTranslation t ON t.CategoryName = p.CategoryName
    WHERE p.CategoryName IS NOT NULL
        AND t.CategoryName IS NULL;
    EXEC qa.usp_LogCheck @RunID, 'oms_category_without_translation', 'LOW';

    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT x.GeoRowID
    FROM (
        SELECT g.GeoRowID,
            ROW_NUMBER() OVER (PARTITION BY g.ZipPrefix, g.Lat, g.Lng, g.City, g.State ORDER BY g.GeoRowID) AS rn
        FROM ref.Geolocation g
    ) x
    WHERE x.rn > 1;
    EXEC qa.usp_LogCheck @RunID, 'ref_geolocation_exact_duplicate', 'LOW';

    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT c.CustomerID
    FROM oms.Customer c
    WHERE NOT EXISTS (SELECT 1 FROM ref.Geolocation g WHERE g.ZipPrefix = c.ZipPrefix);
    EXEC qa.usp_LogCheck @RunID, 'oms_customer_zip_not_in_geo', 'LOW';

    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT s.SellerID
    FROM oms.Seller s
    WHERE NOT EXISTS (SELECT 1 FROM ref.Geolocation g WHERE g.ZipPrefix = s.ZipPrefix);
    EXEC qa.usp_LogCheck @RunID, 'oms_seller_zip_not_in_geo', 'LOW';

    -- oms is sao paulo local, fin closes the month on the raw utc date.
    -- late evening orders on the last day of a month get booked into the next one
    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT DISTINCT o.OrderID
    FROM oms.Orders o
    JOIN fin.LedgerEntry le ON le.OrderID = o.OrderID
    WHERE EOMONTH(o.PurchasedAt) <> EOMONTH(le.PostedDateUTC);
    EXEC qa.usp_LogCheck @RunID, 'fin_booked_in_next_month', 'MEDIUM';

    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT CONCAT(x.OrderID, '/', x.PaymentSeq)
    FROM (
        SELECT le.OrderID, le.PaymentSeq,
            ROW_NUMBER() OVER (PARTITION BY le.OrderID, le.PaymentSeq ORDER BY le.LedgerEntryID) AS rn
        FROM fin.LedgerEntry le
    ) x
    WHERE x.rn > 1;
    EXEC qa.usp_LogCheck @RunID, 'fin_payment_double_posted', 'HIGH';

    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT CONCAT(p.OrderID, '/', p.PaymentSeq)
    FROM pay.Payment p
    LEFT JOIN fin.LedgerEntry le ON le.OrderID = p.OrderID AND le.PaymentSeq = p.PaymentSeq
    WHERE le.LedgerEntryID IS NULL;
    EXEC qa.usp_LogCheck @RunID, 'fin_payment_not_posted', 'HIGH';

    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT CONCAT(le.OrderID, '/', le.PaymentSeq)
    FROM fin.LedgerEntry le
    LEFT JOIN pay.Payment p ON p.OrderID = le.OrderID AND p.PaymentSeq = le.PaymentSeq
    WHERE p.OrderID IS NULL;
    EXEC qa.usp_LogCheck @RunID, 'fin_entry_without_payment', 'HIGH';

    -- guards, these pass on the published data
    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT DISTINCT le.OrderID
    FROM fin.LedgerEntry le
    LEFT JOIN oms.Orders o ON o.OrderID = le.OrderID
    WHERE o.OrderID IS NULL;
    EXEC qa.usp_LogCheck @RunID, 'fin_entry_without_oms_order', 'HIGH';

    TRUNCATE TABLE #hits;
    INSERT INTO #hits (ID)
    SELECT CONCAT(oi.OrderID, '/', oi.OrderItemID)
    FROM oms.OrderItem oi
    WHERE oi.Price <= 0 OR oi.FreightValue < 0;
    EXEC qa.usp_LogCheck @RunID, 'oms_item_bad_price', 'HIGH';
END
GO
