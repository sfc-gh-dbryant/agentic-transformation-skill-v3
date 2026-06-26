-- =============================================================================
-- test_v3_data.sql
-- MarketBasket test dataset for ATS v3 validation.
-- ~50K rows across 4 Bronze tables. Runs in ~30 seconds on XS warehouse.
--
-- Schema: MARKETBASKET_TEST database, BRONZE schema
-- Partners:
--   - SimpleMart:   1 store, no banners, ~5K products    (simple test)
--   - MarketBasket: 3 banners (standard/express/premium) (multi-banner test)
--
-- Run this script once before test_v3_scenarios.sql.
-- =============================================================================

-- ── SETUP ────────────────────────────────────────────────────────────────────

CREATE DATABASE IF NOT EXISTS MARKETBASKET_TEST;
USE DATABASE MARKETBASKET_TEST;

CREATE SCHEMA IF NOT EXISTS BRONZE;
CREATE SCHEMA IF NOT EXISTS AGENT_FRAMEWORK_OUTPUT;  -- v3 safe output schema
CREATE SCHEMA IF NOT EXISTS SILVER;                  -- should stay empty after dry-run tests
CREATE SCHEMA IF NOT EXISTS GOLD;

-- ── PARTNER 1: SimpleMart ─────────────────────────────────────────────────
-- Single store, no banner column. Used for dry-run and safe-output tests.
-- 19 columns including 3 CDC columns — matches Ren's Pets pattern from v2 report.

CREATE OR REPLACE TABLE BRONZE.SIMPLEMART_PRODUCTS AS
WITH b AS (SELECT SEQ4()+1 AS rn FROM TABLE(GENERATOR(ROWCOUNT => 5000)))
SELECT
    rn                                                                      AS PRODUCT_ID,
    'SM-' || LPAD(rn::VARCHAR, 6, '0')                                      AS SKU,
    CASE MOD(rn,8)
        WHEN 0 THEN 'Organic Whole Milk 1L'   WHEN 1 THEN 'Sliced Bread 600g'
        WHEN 2 THEN 'Free Range Eggs 12pk'    WHEN 3 THEN 'Cheddar Cheese 500g'
        WHEN 4 THEN 'Greek Yogurt 750g'       WHEN 5 THEN 'Butter Unsalted 250g'
        WHEN 6 THEN 'Orange Juice 1.5L'       ELSE 'Sourdough Loaf 800g'
    END || ' #' || rn::VARCHAR                                              AS PRODUCT_NAME,
    CASE MOD(rn,5)
        WHEN 0 THEN 'Dairy'    WHEN 1 THEN 'Bakery'
        WHEN 2 THEN 'Produce'  WHEN 3 THEN 'Meat'
        ELSE 'Grocery'
    END                                                                     AS CATEGORY,
    CASE MOD(rn,3)
        WHEN 0 THEN 'en' WHEN 1 THEN 'fr' ELSE 'en'
    END                                                                     AS LANGUAGE_CODE,
    ROUND(UNIFORM(99, 2999, RANDOM()) / 100.0, 2)                           AS PRICE,
    ROUND(UNIFORM(50, 1499, RANDOM()) / 100.0, 2)                           AS COST,
    CASE WHEN MOD(rn, 10) = 0 THEN NULL
         ELSE LPAD(MOD(rn * 7 + 100000, 9999999)::VARCHAR, 7, '0')
    END                                                                     AS UPC,
    CASE WHEN MOD(rn, 4) = 0 THEN 'KG'
         WHEN MOD(rn, 4) = 1 THEN 'L'
         WHEN MOD(rn, 4) = 2 THEN 'UNIT'
         ELSE 'G'
    END                                                                     AS UNIT_OF_MEASURE,
    ROUND(UNIFORM(100, 5000, RANDOM()), 0)::INTEGER                         AS STOCK_QTY,
    CASE WHEN MOD(rn, 20) = 0 THEN FALSE ELSE TRUE END                     AS IS_ACTIVE,
    CASE WHEN MOD(rn, 15) = 0 THEN TRUE  ELSE FALSE END                    AS IS_TAXABLE,
    DATEADD('day', -UNIFORM(0, 730, RANDOM()), CURRENT_DATE())             AS CREATED_DATE,
    DATEADD('day', -UNIFORM(0, 30,  RANDOM()), CURRENT_DATE())             AS UPDATED_DATE,
    MOD(rn, 3) + 1                                                          AS SUPPLIER_ID,
    'store-001'                                                             AS STORE_NUMBER,
    CASE WHEN MOD(rn, 15) = 0 THEN 'UPDATE' ELSE 'INSERT' END              AS _OPERATION,
    CASE WHEN MOD(rn, 100) = 0 THEN TRUE ELSE FALSE END                    AS IS_DELETED,
    DATEADD('second', -UNIFORM(0, 2592000, RANDOM()), CURRENT_TIMESTAMP()) AS _INGEST_TS
FROM b;

-- Quick check
SELECT COUNT(*) AS simplemart_rows,
       COUNT_IF(_OPERATION = 'UPDATE')  AS update_rows,
       COUNT_IF(IS_DELETED = TRUE)      AS deleted_rows,
       COUNT_IF(UPC IS NULL)            AS null_upc_rows
FROM BRONZE.SIMPLEMART_PRODUCTS;

-- ── PARTNER 2: MarketBasket — Multi-Banner ───────────────────────────────
-- 3 banners: standard / express / premium → 3 separate Gold tables.
-- Includes Ancillary category (intentionally excluded from Gold).
-- Models the LCL V2 multi-banner architecture at small scale.

CREATE OR REPLACE TABLE BRONZE.MARKETBASKET_PRODUCTS AS
WITH b AS (SELECT SEQ4()+1 AS rn FROM TABLE(GENERATOR(ROWCOUNT => 40000)))
SELECT
    rn                                                                      AS PRODUCT_ID,
    'MB-' || LPAD(rn::VARCHAR, 8, '0')                                      AS SKU,
    CASE MOD(rn, 6)
        WHEN 0 THEN 'Chicken Breast 1kg'     WHEN 1 THEN 'Pasta Penne 500g'
        WHEN 2 THEN 'Tomato Sauce 680ml'     WHEN 3 THEN 'Sparkling Water 6pk'
        WHEN 4 THEN 'Granola Bar 6pk'        ELSE 'Frozen Pizza 12in'
    END || ' #' || rn::VARCHAR                                              AS PRODUCT_NAME,
    CASE MOD(rn, 7)
        WHEN 0 THEN 'Meat'      WHEN 1 THEN 'Pasta'
        WHEN 2 THEN 'Sauces'    WHEN 3 THEN 'Beverages'
        WHEN 4 THEN 'Snacks'    WHEN 5 THEN 'Frozen'
        ELSE 'Ancillary'  -- intentionally excluded from Gold
    END                                                                     AS CATEGORY,
    CASE MOD(rn, 3)
        WHEN 0 THEN 'standard'
        WHEN 1 THEN 'express'
        ELSE 'premium'
    END                                                                     AS BANNER,
    ROUND(UNIFORM(149, 3999, RANDOM()) / 100.0, 2)                          AS PRICE,
    ROUND(UNIFORM(80,  1999, RANDOM()) / 100.0, 2)                          AS COST,
    CASE WHEN MOD(rn, 30) = 0 THEN NULL
         ELSE LPAD(((rn * 13 + 200000) MOD 9999999)::VARCHAR, 7, '0')
    END                                                                     AS UPC,
    CASE WHEN MOD(rn, 4) = 0 THEN 'KG'
         WHEN MOD(rn, 4) = 1 THEN 'L'
         WHEN MOD(rn, 4) = 2 THEN 'UNIT'
         ELSE 'G'
    END                                                                     AS UNIT_OF_MEASURE,
    ROUND(UNIFORM(0, 4999, RANDOM()), 0)::INTEGER                           AS STOCK_QTY,
    CASE WHEN MOD(rn, 25) = 0 THEN FALSE ELSE TRUE END                     AS IS_ACTIVE,
    CASE WHEN MOD(rn, 12) = 0 THEN TRUE  ELSE FALSE END                    AS IS_TAXABLE,
    CASE WHEN MOD(rn, 3) = 0 THEN 'en' ELSE 'fr' END                      AS NAME_LANGUAGE,
    DATEADD('day', -UNIFORM(0, 1095, RANDOM()), CURRENT_DATE())            AS CREATED_DATE,
    DATEADD('day', -UNIFORM(0, 60,   RANDOM()), CURRENT_DATE())            AS UPDATED_DATE,
    CASE WHEN MOD(rn, 20) = 0 THEN 'UPDATE' ELSE 'INSERT' END              AS _OPERATION,
    CASE WHEN MOD(rn, 200) = 0 THEN TRUE ELSE FALSE END                    AS IS_DELETED,
    DATEADD('second', -UNIFORM(0, 2592000, RANDOM()), CURRENT_TIMESTAMP()) AS _INGEST_TS
FROM b;

-- Breakdown by banner and category
SELECT
    BANNER,
    CATEGORY,
    COUNT(*) AS product_count,
    COUNT_IF(CATEGORY = 'Ancillary') AS ancillary_count
FROM BRONZE.MARKETBASKET_PRODUCTS
GROUP BY BANNER, CATEGORY
ORDER BY BANNER, CATEGORY;

-- ── PRE-BUILT SILVER: MarketBasket ──────────────────────────────────────
-- Simulates existing Silver table that the v3 overwrite check should protect.
-- Stripped CDC columns, excluded deleted rows.

CREATE OR REPLACE TABLE SILVER.MARKETBASKET_PRODUCTS_SILVER AS
SELECT
    PRODUCT_ID, SKU, PRODUCT_NAME, CATEGORY, BANNER,
    PRICE, COST, UPC, UNIT_OF_MEASURE, STOCK_QTY,
    IS_ACTIVE, IS_TAXABLE, NAME_LANGUAGE,
    CREATED_DATE, UPDATED_DATE
FROM BRONZE.MARKETBASKET_PRODUCTS
WHERE IS_DELETED = FALSE
  AND _OPERATION != 'DELETE';

-- ── PRE-BUILT GOLD: MarketBasket banners ────────────────────────────────
-- One Gold table per banner, Ancillary excluded. Used by VALIDATE_MULTI_BANNER.

CREATE OR REPLACE TABLE GOLD.MARKETBASKET_STANDARD AS
SELECT PRODUCT_ID, SKU, PRODUCT_NAME, CATEGORY, PRICE, COST, UPC,
       UNIT_OF_MEASURE, STOCK_QTY, IS_ACTIVE, IS_TAXABLE
FROM SILVER.MARKETBASKET_PRODUCTS_SILVER
WHERE BANNER = 'standard' AND CATEGORY != 'Ancillary';

CREATE OR REPLACE TABLE GOLD.MARKETBASKET_EXPRESS AS
SELECT PRODUCT_ID, SKU, PRODUCT_NAME, CATEGORY, PRICE, COST, UPC,
       UNIT_OF_MEASURE, STOCK_QTY, IS_ACTIVE, IS_TAXABLE
FROM SILVER.MARKETBASKET_PRODUCTS_SILVER
WHERE BANNER = 'express' AND CATEGORY != 'Ancillary';

CREATE OR REPLACE TABLE GOLD.MARKETBASKET_PREMIUM AS
SELECT PRODUCT_ID, SKU, PRODUCT_NAME, CATEGORY, PRICE, COST, UPC,
       UNIT_OF_MEASURE, STOCK_QTY, IS_ACTIVE, IS_TAXABLE
FROM SILVER.MARKETBASKET_PRODUCTS_SILVER
WHERE BANNER = 'premium' AND CATEGORY != 'Ancillary';

-- ── SUMMARY ─────────────────────────────────────────────────────────────

SELECT 'BRONZE.SIMPLEMART_PRODUCTS'          AS tbl, COUNT(*) AS rows FROM BRONZE.SIMPLEMART_PRODUCTS
UNION ALL
SELECT 'BRONZE.MARKETBASKET_PRODUCTS',        COUNT(*) FROM BRONZE.MARKETBASKET_PRODUCTS
UNION ALL
SELECT 'SILVER.MARKETBASKET_PRODUCTS_SILVER', COUNT(*) FROM SILVER.MARKETBASKET_PRODUCTS_SILVER
UNION ALL
SELECT 'GOLD.MARKETBASKET_STANDARD',          COUNT(*) FROM GOLD.MARKETBASKET_STANDARD
UNION ALL
SELECT 'GOLD.MARKETBASKET_EXPRESS',           COUNT(*) FROM GOLD.MARKETBASKET_EXPRESS
UNION ALL
SELECT 'GOLD.MARKETBASKET_PREMIUM',           COUNT(*) FROM GOLD.MARKETBASKET_PREMIUM
ORDER BY tbl;

-- Expected:
--   BRONZE.SIMPLEMART_PRODUCTS:           5,000
--   BRONZE.MARKETBASKET_PRODUCTS:        40,000
--   SILVER.MARKETBASKET_PRODUCTS_SILVER: ~39,800 (minus ~200 deleted rows)
--   GOLD.MARKETBASKET_STANDARD:          ~11,200 (1/3 of silver, minus ~1/7 ancillary)
--   GOLD.MARKETBASKET_EXPRESS:           ~11,200
--   GOLD.MARKETBASKET_PREMIUM:           ~11,200
