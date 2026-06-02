USE OrderRecon;
GO
SET NOCOUNT ON;

-- raw -> typed. TRY_CONVERT so one bad value doesn't kill the load,
-- the audit at the bottom catches anything that silently fell out

INSERT INTO ref.CategoryTranslation (CategoryName, CategoryNameEnglish)
SELECT product_category_name, product_category_name_english
FROM raw.category_translation;

INSERT INTO ref.Geolocation (ZipPrefix, Lat, Lng, City, State)
SELECT geolocation_zip_code_prefix,
    TRY_CONVERT(FLOAT, geolocation_lat),
    TRY_CONVERT(FLOAT, geolocation_lng),
    geolocation_city,
    geolocation_state
FROM raw.geolocation;

INSERT INTO oms.Customer (CustomerID, CustomerUniqueID, ZipPrefix, City, State)
SELECT customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state
FROM raw.customers;

INSERT INTO oms.Seller (SellerID, ZipPrefix, City, State)
SELECT seller_id, seller_zip_code_prefix, seller_city, seller_state
FROM raw.sellers;

-- source spells it "lenght"
INSERT INTO oms.Product (ProductID, CategoryName, NameLength, DescriptionLength, PhotosQty, WeightG, LengthCm, HeightCm, WidthCm)
SELECT product_id,
    NULLIF(product_category_name, ''),
    TRY_CONVERT(SMALLINT, NULLIF(product_name_lenght, '')),
    TRY_CONVERT(SMALLINT, NULLIF(product_description_lenght, '')),
    TRY_CONVERT(TINYINT, NULLIF(product_photos_qty, '')),
    TRY_CONVERT(INT, NULLIF(product_weight_g, '')),
    TRY_CONVERT(SMALLINT, NULLIF(product_length_cm, '')),
    TRY_CONVERT(SMALLINT, NULLIF(product_height_cm, '')),
    TRY_CONVERT(SMALLINT, NULLIF(product_width_cm, ''))
FROM raw.products;

INSERT INTO oms.Orders (OrderID, CustomerID, OrderStatus, PurchasedAt, ApprovedAt, DeliveredCarrierAt, DeliveredCustomerAt, EstimatedDeliveryDate)
SELECT order_id,
    customer_id,
    order_status,
    TRY_CONVERT(DATETIME2(0), order_purchase_timestamp, 120),
    TRY_CONVERT(DATETIME2(0), NULLIF(order_approved_at, ''), 120),
    TRY_CONVERT(DATETIME2(0), NULLIF(order_delivered_carrier_date, ''), 120),
    TRY_CONVERT(DATETIME2(0), NULLIF(order_delivered_customer_date, ''), 120),
    TRY_CONVERT(DATE, NULLIF(order_estimated_delivery_date, ''), 120)
FROM raw.orders;

INSERT INTO oms.OrderItem (OrderID, OrderItemID, ProductID, SellerID, ShippingLimitAt, Price, FreightValue)
SELECT order_id,
    TRY_CONVERT(TINYINT, order_item_id),
    product_id,
    seller_id,
    TRY_CONVERT(DATETIME2(0), shipping_limit_date, 120),
    TRY_CONVERT(DECIMAL(12,2), price),
    TRY_CONVERT(DECIMAL(12,2), freight_value)
FROM raw.order_items;

INSERT INTO oms.Review (ReviewID, OrderID, Score, CommentTitle, CommentMessage, CreatedDate, AnsweredAt)
SELECT review_id,
    order_id,
    TRY_CONVERT(TINYINT, review_score),
    NULLIF(review_comment_title, ''),
    NULLIF(review_comment_message, ''),
    TRY_CONVERT(DATE, review_creation_date, 120),
    TRY_CONVERT(DATETIME2(0), review_answer_timestamp, 120)
FROM raw.order_reviews;

INSERT INTO pay.Payment (OrderID, PaymentSeq, PaymentType, Installments, Amount)
SELECT order_id,
    TRY_CONVERT(TINYINT, payment_sequential),
    payment_type,
    TRY_CONVERT(TINYINT, payment_installments),
    TRY_CONVERT(DECIMAL(12,2), payment_value)
FROM raw.order_payments;

-- source vs target row counts for the initial import
INSERT INTO etl.LoadAudit (TableName, SourceRows, LoadedRows)
SELECT 'CategoryTranslation', (SELECT COUNT(*) FROM raw.category_translation), (SELECT COUNT(*) FROM ref.CategoryTranslation)
UNION ALL SELECT 'Geolocation', (SELECT COUNT(*) FROM raw.geolocation), (SELECT COUNT(*) FROM ref.Geolocation)
UNION ALL SELECT 'Customer', (SELECT COUNT(*) FROM raw.customers), (SELECT COUNT(*) FROM oms.Customer)
UNION ALL SELECT 'Seller', (SELECT COUNT(*) FROM raw.sellers), (SELECT COUNT(*) FROM oms.Seller)
UNION ALL SELECT 'Product', (SELECT COUNT(*) FROM raw.products), (SELECT COUNT(*) FROM oms.Product)
UNION ALL SELECT 'Orders', (SELECT COUNT(*) FROM raw.orders), (SELECT COUNT(*) FROM oms.Orders)
UNION ALL SELECT 'OrderItem', (SELECT COUNT(*) FROM raw.order_items), (SELECT COUNT(*) FROM oms.OrderItem)
UNION ALL SELECT 'Review', (SELECT COUNT(*) FROM raw.order_reviews), (SELECT COUNT(*) FROM oms.Review)
UNION ALL SELECT 'Payment', (SELECT COUNT(*) FROM raw.order_payments), (SELECT COUNT(*) FROM pay.Payment);

-- raw is utf8 collated, hence the COLLATE on the joins.
-- a value that failed TRY_CONVERT would show up as NULL in a column the raw file had filled
SELECT 'orders bad timestamp' AS chk, COUNT(*) AS n
FROM raw.orders r
JOIN oms.Orders o ON o.OrderID = r.order_id COLLATE DATABASE_DEFAULT
WHERE (o.ApprovedAt IS NULL AND r.order_approved_at <> '')
    OR (o.DeliveredCarrierAt IS NULL AND r.order_delivered_carrier_date <> '')
    OR (o.DeliveredCustomerAt IS NULL AND r.order_delivered_customer_date <> '')
UNION ALL
SELECT 'products bad number', COUNT(*)
FROM raw.products r
JOIN oms.Product p ON p.ProductID = r.product_id COLLATE DATABASE_DEFAULT
WHERE (p.WeightG IS NULL AND r.product_weight_g <> '')
    OR (p.NameLength IS NULL AND r.product_name_lenght <> '');

SELECT TableName, SourceRows, LoadedRows, Result
FROM etl.LoadAudit
ORDER BY LoadAuditID;
GO
