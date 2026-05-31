USE OrderRecon;
GO

-- landing zone. everything is text, exactly as it comes out of the csv,
-- typing and cleanup happen in 03 so a bad value never fails the load
CREATE SCHEMA raw;
GO

-- utf8 collation on the raw columns because BULK INSERT on linux has no CODEPAGE option.
-- the bytes land as-is and the portuguese accents in reviews survive

CREATE TABLE raw.customers (
    customer_id VARCHAR(50) COLLATE Latin1_General_100_CI_AS_SC_UTF8, customer_unique_id VARCHAR(50) COLLATE Latin1_General_100_CI_AS_SC_UTF8, customer_zip_code_prefix VARCHAR(10) COLLATE Latin1_General_100_CI_AS_SC_UTF8,
    customer_city VARCHAR(100) COLLATE Latin1_General_100_CI_AS_SC_UTF8, customer_state VARCHAR(10) COLLATE Latin1_General_100_CI_AS_SC_UTF8
);
CREATE TABLE raw.geolocation (
    geolocation_zip_code_prefix VARCHAR(10) COLLATE Latin1_General_100_CI_AS_SC_UTF8, geolocation_lat VARCHAR(40) COLLATE Latin1_General_100_CI_AS_SC_UTF8, geolocation_lng VARCHAR(40) COLLATE Latin1_General_100_CI_AS_SC_UTF8,
    geolocation_city VARCHAR(100) COLLATE Latin1_General_100_CI_AS_SC_UTF8, geolocation_state VARCHAR(10) COLLATE Latin1_General_100_CI_AS_SC_UTF8
);
CREATE TABLE raw.order_items (
    order_id VARCHAR(50) COLLATE Latin1_General_100_CI_AS_SC_UTF8, order_item_id VARCHAR(10) COLLATE Latin1_General_100_CI_AS_SC_UTF8, product_id VARCHAR(50) COLLATE Latin1_General_100_CI_AS_SC_UTF8, seller_id VARCHAR(50) COLLATE Latin1_General_100_CI_AS_SC_UTF8,
    shipping_limit_date VARCHAR(30) COLLATE Latin1_General_100_CI_AS_SC_UTF8, price VARCHAR(20) COLLATE Latin1_General_100_CI_AS_SC_UTF8, freight_value VARCHAR(20) COLLATE Latin1_General_100_CI_AS_SC_UTF8
);
CREATE TABLE raw.order_payments (
    order_id VARCHAR(50) COLLATE Latin1_General_100_CI_AS_SC_UTF8, payment_sequential VARCHAR(10) COLLATE Latin1_General_100_CI_AS_SC_UTF8, payment_type VARCHAR(30) COLLATE Latin1_General_100_CI_AS_SC_UTF8,
    payment_installments VARCHAR(10) COLLATE Latin1_General_100_CI_AS_SC_UTF8, payment_value VARCHAR(20) COLLATE Latin1_General_100_CI_AS_SC_UTF8
);
CREATE TABLE raw.order_reviews (
    review_id VARCHAR(50) COLLATE Latin1_General_100_CI_AS_SC_UTF8, order_id VARCHAR(50) COLLATE Latin1_General_100_CI_AS_SC_UTF8, review_score VARCHAR(10) COLLATE Latin1_General_100_CI_AS_SC_UTF8, review_comment_title VARCHAR(200) COLLATE Latin1_General_100_CI_AS_SC_UTF8,
    review_comment_message VARCHAR(1000) COLLATE Latin1_General_100_CI_AS_SC_UTF8, review_creation_date VARCHAR(30) COLLATE Latin1_General_100_CI_AS_SC_UTF8, review_answer_timestamp VARCHAR(30) COLLATE Latin1_General_100_CI_AS_SC_UTF8
);
CREATE TABLE raw.orders (
    order_id VARCHAR(50) COLLATE Latin1_General_100_CI_AS_SC_UTF8, customer_id VARCHAR(50) COLLATE Latin1_General_100_CI_AS_SC_UTF8, order_status VARCHAR(20) COLLATE Latin1_General_100_CI_AS_SC_UTF8, order_purchase_timestamp VARCHAR(30) COLLATE Latin1_General_100_CI_AS_SC_UTF8,
    order_approved_at VARCHAR(30) COLLATE Latin1_General_100_CI_AS_SC_UTF8, order_delivered_carrier_date VARCHAR(30) COLLATE Latin1_General_100_CI_AS_SC_UTF8,
    order_delivered_customer_date VARCHAR(30) COLLATE Latin1_General_100_CI_AS_SC_UTF8, order_estimated_delivery_date VARCHAR(30) COLLATE Latin1_General_100_CI_AS_SC_UTF8
);
-- the typo in the column names is in the source file, kept here and fixed in 03
CREATE TABLE raw.products (
    product_id VARCHAR(50) COLLATE Latin1_General_100_CI_AS_SC_UTF8, product_category_name VARCHAR(100) COLLATE Latin1_General_100_CI_AS_SC_UTF8, product_name_lenght VARCHAR(10) COLLATE Latin1_General_100_CI_AS_SC_UTF8,
    product_description_lenght VARCHAR(10) COLLATE Latin1_General_100_CI_AS_SC_UTF8, product_photos_qty VARCHAR(10) COLLATE Latin1_General_100_CI_AS_SC_UTF8, product_weight_g VARCHAR(10) COLLATE Latin1_General_100_CI_AS_SC_UTF8,
    product_length_cm VARCHAR(10) COLLATE Latin1_General_100_CI_AS_SC_UTF8, product_height_cm VARCHAR(10) COLLATE Latin1_General_100_CI_AS_SC_UTF8, product_width_cm VARCHAR(10) COLLATE Latin1_General_100_CI_AS_SC_UTF8
);
CREATE TABLE raw.sellers (
    seller_id VARCHAR(50) COLLATE Latin1_General_100_CI_AS_SC_UTF8, seller_zip_code_prefix VARCHAR(10) COLLATE Latin1_General_100_CI_AS_SC_UTF8, seller_city VARCHAR(100) COLLATE Latin1_General_100_CI_AS_SC_UTF8, seller_state VARCHAR(10) COLLATE Latin1_General_100_CI_AS_SC_UTF8
);
CREATE TABLE raw.category_translation (
    product_category_name VARCHAR(100) COLLATE Latin1_General_100_CI_AS_SC_UTF8, product_category_name_english VARCHAR(100) COLLATE Latin1_General_100_CI_AS_SC_UTF8
);
GO

-- FORMAT = 'CSV' handles the inconsistent quoting and the line breaks inside review comments.
-- reviews and the translation file are crlf, the rest are lf
BULK INSERT raw.customers FROM '/data/olist/olist_customers_dataset.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT raw.geolocation FROM '/data/olist/olist_geolocation_dataset.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT raw.order_items FROM '/data/olist/olist_order_items_dataset.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT raw.order_payments FROM '/data/olist/olist_order_payments_dataset.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT raw.order_reviews FROM '/data/olist/olist_order_reviews_dataset.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0d0a', TABLOCK);
BULK INSERT raw.orders FROM '/data/olist/olist_orders_dataset.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT raw.products FROM '/data/olist/olist_products_dataset.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT raw.sellers FROM '/data/olist/olist_sellers_dataset.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT raw.category_translation FROM '/data/olist/product_category_name_translation.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0d0a', TABLOCK);
GO

SET NOCOUNT ON;
SELECT 'customers' AS tbl, COUNT(*) AS cnt FROM raw.customers
UNION ALL SELECT 'geolocation', COUNT(*) FROM raw.geolocation
UNION ALL SELECT 'order_items', COUNT(*) FROM raw.order_items
UNION ALL SELECT 'order_payments', COUNT(*) FROM raw.order_payments
UNION ALL SELECT 'order_reviews', COUNT(*) FROM raw.order_reviews
UNION ALL SELECT 'orders', COUNT(*) FROM raw.orders
UNION ALL SELECT 'products', COUNT(*) FROM raw.products
UNION ALL SELECT 'sellers', COUNT(*) FROM raw.sellers
UNION ALL SELECT 'category_translation', COUNT(*) FROM raw.category_translation;
GO
