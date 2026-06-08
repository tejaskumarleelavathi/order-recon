-- rewrite of old_monthly_revenue.sql.
--
-- what was wrong: items and payments are both children of orders, and the old report
-- joined both in one comma list. nothing relates an item row to a payment row, so an order
-- with 3 items and 2 payments (voucher + card is common) came back as 6 rows: every item
-- counted twice and every payment counted three times. COUNT(DISTINCT) kept the order count
-- right, which is why it looked fine. in the WHERE-clause style there's no visual cue that
-- a join is missing a relationship, it just reads like a list of filters.
--
-- fix: aggregate each child to one row per order first, then join. INNER for items
-- (no items, no revenue), LEFT for payments so an order with no payment record still
-- shows its revenue instead of silently dropping out.
USE OrderRecon;

WITH items AS (
    SELECT oi.OrderID, SUM(oi.Price) AS ProductRevenue, SUM(oi.FreightValue) AS Freight
    FROM oms.OrderItem oi
    GROUP BY oi.OrderID
),
paid AS (
    SELECT p.OrderID, SUM(p.Amount) AS Paid
    FROM pay.Payment p
    GROUP BY p.OrderID
)
SELECT DATEFROMPARTS(YEAR(o.PurchasedAt), MONTH(o.PurchasedAt), 1) AS SalesMonth,
    COUNT(*) AS Orders,
    SUM(i.ProductRevenue) AS ProductRevenue,
    SUM(i.Freight) AS Freight,
    SUM(ISNULL(pd.Paid, 0)) AS Paid
FROM oms.Orders o
INNER JOIN items i ON i.OrderID = o.OrderID
LEFT JOIN paid pd ON pd.OrderID = o.OrderID
WHERE o.OrderStatus = 'delivered'
    AND o.PurchasedAt >= '2017-01-01'
    AND o.PurchasedAt < '2018-09-01'
GROUP BY DATEFROMPARTS(YEAR(o.PurchasedAt), MONTH(o.PurchasedAt), 1)
ORDER BY SalesMonth;
