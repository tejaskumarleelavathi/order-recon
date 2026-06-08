-- monthly revenue for delivered orders, for the close deck.
-- products revenue, freight, and what customers actually paid
USE OrderRecon;

SELECT DATEFROMPARTS(YEAR(o.PurchasedAt), MONTH(o.PurchasedAt), 1) AS SalesMonth,
    COUNT(DISTINCT o.OrderID) AS Orders,
    SUM(oi.Price) AS ProductRevenue,
    SUM(oi.FreightValue) AS Freight,
    SUM(p.Amount) AS Paid
FROM oms.Orders o, oms.OrderItem oi, pay.Payment p
WHERE o.OrderID = oi.OrderID
    AND o.OrderID = p.OrderID
    AND o.OrderStatus = 'delivered'
    AND o.PurchasedAt >= '2017-01-01'
    AND o.PurchasedAt < '2018-09-01'
GROUP BY DATEFROMPARTS(YEAR(o.PurchasedAt), MONTH(o.PurchasedAt), 1)
ORDER BY SalesMonth;
