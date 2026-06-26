-- =============================================================================
-- ATS v3 Full Test Battery — Complete Dataset
-- Test dataset for ATS v3 validation suite
--
-- Partners:
--   1. Ren's Pets        — Simple (5,709 rows, 19 composite key dupes, bilingual)
--   2. DashMart Canada   — Medium (18K rows, NAME_FR QC, IS_TAXABLE, 5 provinces)
--   3. LCL V2            — Complex (50K rows, 14 banners, valid_from dedup,
--                          Ancillary/Liquor exclusion, 29% bad UPCs)
--
-- Also creates pre-built Silver + Gold for overwrite protection tests.
-- =============================================================================

USE DATABASE ATS_V3_TEST;
CREATE SCHEMA IF NOT EXISTS BRONZE;
CREATE SCHEMA IF NOT EXISTS SILVER;
CREATE SCHEMA IF NOT EXISTS GOLD;

-- =============================================================================
-- PARTNER 1: REN'S PETS  (Simple)
-- Source data: 5,709 rows, 19 duplicate composite keys, store='undefined',
-- 19 columns including IMAGES VARIANT, OFFER_PRICE_DETAILS, _STAGE,
-- bilingual images (en+fr), 4 provinces, no valid_from (no dedup needed)
-- =============================================================================

CREATE OR REPLACE TABLE BRONZE.RENSPETS_PRODUCTS AS
WITH nums AS (
    SELECT SEQ4() AS n FROM TABLE(GENERATOR(ROWCOUNT => 5709))
)
SELECT
    -- UPC: 12-digit, leading-zero format
    -- ~19 products intentionally share a UPC with another product (composite key dupes)
    LPAD(TO_VARCHAR(1000000 + MOD(n, 5690)), 12, '0')              AS UPC,
    -- PRODUCT_KEY: the composite key — 19 pairs share same UPC (rows 0-37)
    CASE WHEN n < 38 THEN 'ALTPROD-' || TO_VARCHAR(n)
         ELSE 'PROD-' || TO_VARCHAR(n) END                         AS PRODUCT_KEY,
    'Product Name ' || TO_VARCHAR(n)                               AS TITLE,
    CASE MOD(n,4) WHEN 0 THEN '500ml' WHEN 1 THEN '1kg'
                  WHEN 2 THEN '250g'  ELSE '1ea' END               AS SIZE,
    CASE MOD(n,3) WHEN 0 THEN 'EA' WHEN 1 THEN 'KG' ELSE 'LT' END AS UNIT_OF_MEASURE,
    ROUND(4.99 + MOD(n, 45) * 0.55, 2)                            AS ORIGINAL_PRICE,
    ROUND((4.99 + MOD(n, 45) * 0.55) * 0.88, 2)                   AS SALE_PRICE,
    CASE MOD(n,4) WHEN 0 THEN 'ON' WHEN 1 THEN 'QC'
                  WHEN 2 THEN 'BC' ELSE 'AB' END                   AS PROVINCE,
    'undefined'                                                    AS STORE_NUMBER,
    (MOD(n, 10) > 2)                                               AS IS_TAXABLE,
    PARSE_JSON('{"regular":' || ROUND(4.99+MOD(n,45)*0.55,2)::VARCHAR ||
               ',"sale":'   || ROUND((4.99+MOD(n,45)*0.55)*0.88,2)::VARCHAR ||
               ',"currency":"CAD"}')                               AS OFFER_PRICE_DETAILS,
    -- Bilingual images — 2 entries per row (en + fr)
    PARSE_JSON('[{"lang":"en","url":"https://cdn.renspets.com/en/' ||
               LPAD(TO_VARCHAR(1000000+MOD(n,5690)),12,'0') || '.jpg"},' ||
               '{"lang":"fr","url":"https://cdn.renspets.com/fr/' ||
               LPAD(TO_VARCHAR(1000000+MOD(n,5690)),12,'0') || '.jpg"}]') AS IMAGES,
    CASE MOD(n,4) WHEN 0 THEN 'pet_food' WHEN 1 THEN 'pet_supplies'
                  WHEN 2 THEN 'grooming' ELSE 'toys' END           AS CATEGORY,
    DATEADD(day, -MOD(n,365), '2025-01-01'::DATE)::TIMESTAMP       AS TIMESTAMP,
    DATEADD(minute, n, '2024-06-01 00:00:00'::TIMESTAMP)           AS INTIME,
    'renspets_stage'                                               AS _STAGE,
    'RENSPETS'                                                     AS PARTNER
FROM nums;


-- =============================================================================
-- PARTNER 2: DASHMART CANADA  (Medium)
-- Source data: 181,640 rows (scaled to 18K for test), 14,747 composite
-- key dupes, NAME_FR populated ONLY for QC rows, IS_TAXABLE computed,
-- gst_hst_tax_rate + pst_qst_tax_rate inline, 5 provinces, 19 stores,
-- no valid_from (no dedup), single language images (en only)
-- =============================================================================

CREATE OR REPLACE TABLE BRONZE.DASHMART_PRODUCTS AS
WITH nums AS (
    SELECT SEQ4() AS n FROM TABLE(GENERATOR(ROWCOUNT => 18200))
)
SELECT
    LPAD(TO_VARCHAR(2000000 + MOD(n, 17700)), 12, '0')             AS UPC,
    -- ~1,470 composite key dupes (~8% of total rows)
    CASE WHEN MOD(n, 12) = 0 THEN 'DM-DUP-' || TO_VARCHAR(MOD(n,1470))
         ELSE 'DM-' || TO_VARCHAR(n) END                           AS PRODUCT_KEY,
    'DashMart Product ' || TO_VARCHAR(n)                           AS NAME,
    -- NAME_FR only populated for QC rows (8,369/8,369 QC rows had NAME_FR)
    CASE WHEN MOD(n,5) = 1  -- ~20% are QC
         THEN 'Produit DashMart ' || TO_VARCHAR(n)
         ELSE NULL END                                             AS NAME_FR,
    ROUND(3.99 + MOD(n, 60) * 0.45, 2)                            AS ORIGINAL_PRICE,
    ROUND((3.99 + MOD(n, 60) * 0.45) * 0.92, 2)                   AS SALE_PRICE,
    -- IS_TAXABLE: 116,010/181,640 taxable (~64%)
    (MOD(n, 100) < 64)                                             AS IS_TAXABLE,
    -- Province: 5 provinces
    CASE MOD(n,5) WHEN 0 THEN 'ON' WHEN 1 THEN 'QC' WHEN 2 THEN 'BC'
                  WHEN 3 THEN 'AB' ELSE 'MB' END                   AS PROVINCE,
    -- GST/HST and PST/QST inline per row (no separate tax table)
    CASE WHEN MOD(n,5) = 0 AND MOD(n,100) < 64 THEN 0.13
         WHEN MOD(n,5) IN (2,4) AND MOD(n,100) < 64 THEN 0.05
         WHEN MOD(n,5) = 3 AND MOD(n,100) < 64 THEN 0.05
         ELSE 0.0 END                                              AS GST_HST_TAX_RATE,
    CASE WHEN MOD(n,5) = 1 AND MOD(n,100) < 64 THEN 0.09975
         WHEN MOD(n,5) = 2 AND MOD(n,100) < 64 THEN 0.07
         ELSE 0.0 END                                              AS PST_QST_TAX_RATE,
    -- 19 stores
    'STORE-' || LPAD(TO_VARCHAR(MOD(n,19)+1), 3, '0')             AS STORE_NUMBER,
    -- Images: single language en only
    PARSE_JSON('[{"lang":"en","url":"https://cdn.dashmart.ca/en/' ||
               LPAD(TO_VARCHAR(2000000+MOD(n,17700)),12,'0') || '.jpg"}]') AS IMAGES,
    CASE MOD(n,6) WHEN 0 THEN 'grocery' WHEN 1 THEN 'dairy'
                  WHEN 2 THEN 'frozen'  WHEN 3 THEN 'snacks'
                  WHEN 4 THEN 'beverage' ELSE 'household' END      AS CATEGORY,
    -- udfSplitTitle at char 330 pattern (NAME_FR split at char 330)
    CASE WHEN MOD(n,5) = 1
         THEN SUBSTR('DashMart Product ' || TO_VARCHAR(n), 1, 330)
         ELSE NULL END                                             AS SPLIT_TITLE_OFFSET,
    DATEADD(minute, n, '2024-07-01 00:00:00'::TIMESTAMP)           AS INGEST_TIMESTAMP,
    'DASHMART_CA'                                                  AS PARTNER
FROM nums;


-- =============================================================================
-- PARTNER 3: LCL V2  (Complex / Multi-Banner)
-- Source data characteristics:
--   ~198M Bronze rows (scaled to 50K), 3 source tables → unified Bronze
--   14 banners in Silver, 13 Gold tables (your_ind_grocer has NO Gold table)
--   valid_from DESC + liam EA>KG>other tie-break dedup
--   29% UPCs lack leading zero (410xxx coupon/promo series)
--   Gold filter: Ancillary + Liquor EXCLUDED → Gold < Silver by design
--   ICM banner merges into 'independent'
--   Zehrs Silver = staging table containing ALL banners (pre-dedup)
--   Price in dollars (already converted from cents)
--   Bilingual images (en + fr)
--   Dynamic tax: PPFT/SPFT flags
-- =============================================================================

CREATE OR REPLACE TABLE BRONZE.LCL_PRODUCTS AS
WITH nums AS (
    SELECT SEQ4() AS n FROM TABLE(GENERATOR(ROWCOUNT => 50000))
),
banner_assign AS (
    SELECT n,
        CASE MOD(n,14)
            WHEN 0  THEN 'superstore'
            WHEN 1  THEN 'nofrills'
            WHEN 2  THEN 'maxi'
            WHEN 3  THEN 'independent'
            WHEN 4  THEN 'rass'
            WHEN 5  THEN 'zehrs'
            WHEN 6  THEN 'loblaws'
            WHEN 7  THEN 'wholesaleclub'
            WHEN 8  THEN 'fortinos'
            WHEN 9  THEN 'dominion'
            WHEN 10 THEN 'provigo'
            WHEN 11 THEN 'valumart'
            WHEN 12 THEN 'independentcitymarket'
            ELSE         'your_ind_grocer'
        END AS banner,
        -- Source table assignment (3 Bronze sources: LCL, Zehrs, Valumart)
        CASE WHEN MOD(n,14) IN (5)               THEN 'ZEHRS_BRONZE'
             WHEN MOD(n,14) IN (11)              THEN 'VALUMART_BRONZE'
             ELSE                                     'LCL_BRONZE'
        END AS source_table,
        -- Category: ~5% Ancillary, ~3% Liquor (excluded from Gold by design)
        CASE WHEN MOD(n,20) = 0  THEN 'Ancillary'
             WHEN MOD(n,33) = 0  THEN 'Liquor'
             WHEN MOD(n,7)  = 0  THEN 'Grocery'
             WHEN MOD(n,7)  = 1  THEN 'Dairy'
             WHEN MOD(n,7)  = 2  THEN 'Frozen'
             WHEN MOD(n,7)  = 3  THEN 'Bakery'
             WHEN MOD(n,7)  = 4  THEN 'Produce'
             WHEN MOD(n,7)  = 5  THEN 'Meat'
             ELSE                     'Household'
        END AS category,
        -- liam tie-break column: EA > KG > other
        CASE MOD(n,3) WHEN 0 THEN 'EA' WHEN 1 THEN 'KG' ELSE 'OTHER' END AS liam,
        -- 29% of UPCs lack leading zero (410xxx coupon/promo series)
        CASE WHEN MOD(n,100) < 29
             THEN TO_VARCHAR(4100000 + MOD(n,100000))        -- no leading zero (410xxx)
             ELSE LPAD(TO_VARCHAR(3000000 + MOD(n,200000)), 12, '0')  -- standard format
        END AS upc_raw
    FROM nums
)
SELECT
    upc_raw                                                        AS UPC,
    banner                                                         AS BANNER,
    source_table                                                   AS SOURCE_TABLE,
    category                                                       AS CATEGORY,
    liam                                                           AS LIAM,
    'LCL Product ' || TO_VARCHAR(n)                               AS TITLE,
    'Produit LCL ' || TO_VARCHAR(n)                               AS TITLE_FR,
    -- Price in dollars (already converted from cents)
    ROUND(1.99 + MOD(n, 80) * 0.75, 2)                           AS PRICE,
    ROUND((1.99 + MOD(n, 80) * 0.75) * 0.90, 2)                  AS SALE_PRICE,
    -- valid_from: multiple versions per UPC+banner for dedup testing
    -- Latest valid_from wins → ROW_NUMBER() OVER (PARTITION BY upc,banner ORDER BY valid_from DESC)
    DATEADD(day, -MOD(n,365), '2025-06-01'::DATE)::TIMESTAMP      AS VALID_FROM,
    -- Older duplicate versions (same UPC+banner, older valid_from) — ~20% of rows
    CASE WHEN MOD(n, 5) = 0
         THEN DATEADD(day, -(365 + MOD(n,180)), '2025-06-01'::DATE)::TIMESTAMP
         ELSE NULL END                                             AS VALID_FROM_OLD,
    -- PPFT/SPFT: dynamic tax flags (MongoDB-driven, not static)
    (MOD(n, 50) = 0)                                              AS PPFT_FLAG,
    (MOD(n, 75) = 0)                                              AS SPFT_FLAG,
    (MOD(n, 10) > 2)                                              AS IS_TAXABLE,
    'STORE-LCL-' || LPAD(TO_VARCHAR(MOD(n,50)+1), 3, '0')        AS STORE_ID,
    -- Bilingual images (2 entries per Gold row)
    PARSE_JSON('[{"lang":"en","url":"https://cdn.lcl.ca/en/' || upc_raw || '.jpg"},' ||
               '{"lang":"fr","url":"https://cdn.lcl.ca/fr/' || upc_raw || '.jpg"}]') AS IMAGES,
    DATEADD(minute, n, '2024-01-01 00:00:00'::TIMESTAMP)          AS INGEST_TIMESTAMP,
    'LCL_V2'                                                      AS PARTNER
FROM banner_assign;


-- =============================================================================
-- PRE-BUILT SILVER TABLE: RENSPETS (for overwrite protection test T-03)
-- Simulates production Silver that must NOT be overwritten
-- =============================================================================

CREATE OR REPLACE TABLE SILVER.RENSPETS_PRODUCTS_SILVER AS
SELECT
    UPC, PRODUCT_KEY, TITLE, SIZE, UNIT_OF_MEASURE,
    ORIGINAL_PRICE, SALE_PRICE, PROVINCE, STORE_NUMBER,
    IS_TAXABLE, CATEGORY, TIMESTAMP, INTIME, _STAGE, PARTNER,
    CURRENT_TIMESTAMP()                                            AS _SILVER_LOADED_AT,
    'PRODUCTION'                                                   AS _SILVER_ENV
FROM BRONZE.RENSPETS_PRODUCTS
WHERE PRODUCT_KEY NOT LIKE 'ALTPROD-%';  -- deduped: 5,709 - 19 dupes = 5,690 rows


-- =============================================================================
-- PRE-BUILT SILVER TABLE: LCL (staging — ALL banners, pre-dedup)
-- Zehrs Silver is intentionally a staging table containing ALL banners
-- Key routing pattern for LCL V2
-- =============================================================================

CREATE OR REPLACE TABLE SILVER.LCL_PRODUCTS_SILVER AS
SELECT
    UPC, BANNER, SOURCE_TABLE, CATEGORY, LIAM,
    TITLE, TITLE_FR, PRICE, SALE_PRICE, VALID_FROM,
    IS_TAXABLE, PPFT_FLAG, SPFT_FLAG, STORE_ID, IMAGES, PARTNER,
    ROW_NUMBER() OVER (
        PARTITION BY UPC, BANNER
        ORDER BY VALID_FROM DESC,
                 CASE LIAM WHEN 'EA' THEN 1 WHEN 'KG' THEN 2 ELSE 3 END
    )                                                              AS _dedup_rank,
    CURRENT_TIMESTAMP()                                            AS _SILVER_LOADED_AT
FROM BRONZE.LCL_PRODUCTS
WHERE CATEGORY NOT IN ('Ancillary', 'Liquor');  -- Gold filter applied at Silver stage


-- Keep only rank=1 (deduped) rows for the clean Silver view
CREATE OR REPLACE TABLE SILVER.LCL_PRODUCTS_SILVER_DEDUPED AS
SELECT * EXCLUDE (_dedup_rank) FROM SILVER.LCL_PRODUCTS_SILVER
WHERE _dedup_rank = 1;


-- =============================================================================
-- PRE-BUILT GOLD TABLES: LCL 13 banner tables
-- your_ind_grocer intentionally has NO Gold table (one banner maps to null)
-- ICM (independentcitymarket) merges into independent Gold table
-- Ancillary + Liquor excluded: Gold < Silver by design
-- =============================================================================

CREATE OR REPLACE TABLE GOLD.LCL_GOLD_SUPERSTORE     AS SELECT * FROM SILVER.LCL_PRODUCTS_SILVER_DEDUPED WHERE BANNER = 'superstore';
CREATE OR REPLACE TABLE GOLD.LCL_GOLD_NOFRILLS       AS SELECT * FROM SILVER.LCL_PRODUCTS_SILVER_DEDUPED WHERE BANNER = 'nofrills';
CREATE OR REPLACE TABLE GOLD.LCL_GOLD_MAXI           AS SELECT * FROM SILVER.LCL_PRODUCTS_SILVER_DEDUPED WHERE BANNER = 'maxi';
-- ICM merges into independent Gold table (both banners in one Gold table)
CREATE OR REPLACE TABLE GOLD.LCL_GOLD_INDEPENDENT    AS SELECT * FROM SILVER.LCL_PRODUCTS_SILVER_DEDUPED WHERE BANNER IN ('independent','independentcitymarket');
CREATE OR REPLACE TABLE GOLD.LCL_GOLD_RASS           AS SELECT * FROM SILVER.LCL_PRODUCTS_SILVER_DEDUPED WHERE BANNER = 'rass';
CREATE OR REPLACE TABLE GOLD.LCL_GOLD_ZEHRS          AS SELECT * FROM SILVER.LCL_PRODUCTS_SILVER_DEDUPED WHERE BANNER = 'zehrs';
CREATE OR REPLACE TABLE GOLD.LCL_GOLD_LOBLAWS        AS SELECT * FROM SILVER.LCL_PRODUCTS_SILVER_DEDUPED WHERE BANNER = 'loblaws';
CREATE OR REPLACE TABLE GOLD.LCL_GOLD_WHOLESALECLUB  AS SELECT * FROM SILVER.LCL_PRODUCTS_SILVER_DEDUPED WHERE BANNER = 'wholesaleclub';
CREATE OR REPLACE TABLE GOLD.LCL_GOLD_FORTINOS       AS SELECT * FROM SILVER.LCL_PRODUCTS_SILVER_DEDUPED WHERE BANNER = 'fortinos';
CREATE OR REPLACE TABLE GOLD.LCL_GOLD_DOMINION       AS SELECT * FROM SILVER.LCL_PRODUCTS_SILVER_DEDUPED WHERE BANNER = 'dominion';
CREATE OR REPLACE TABLE GOLD.LCL_GOLD_PROVIGO        AS SELECT * FROM SILVER.LCL_PRODUCTS_SILVER_DEDUPED WHERE BANNER = 'provigo';
CREATE OR REPLACE TABLE GOLD.LCL_GOLD_VALUMART       AS SELECT * FROM SILVER.LCL_PRODUCTS_SILVER_DEDUPED WHERE BANNER = 'valumart';
-- your_ind_grocer intentionally has NO Gold table (NULL gold_table in PARTNER_BANNER_CONFIG)


-- =============================================================================
-- NOTE: Table registration is handled by BOOTSTRAP.
-- After this script runs, call:
--   CALL ATS_V3.AGENT_FRAMEWORK.BOOTSTRAP('ATS_V3_TEST.BRONZE');
-- Bootstrap will discover all tables in ATS_V3_TEST.BRONZE automatically.
-- For multi-source (e.g. adding Silver as a source for brownfield validation):
--   CALL ATS_V3.AGENT_FRAMEWORK.BOOTSTRAP('ATS_V3_TEST.BRONZE,ATS_V3_TEST.SILVER');

-- SEED LCL BANNER CONFIG (uses AGENT_FRAMEWORK SP we already deployed)
-- Maps 14 banners → 13 Gold tables with exclusion rules and merge targets
-- =============================================================================

USE DATABASE ATS_V3;
CALL AGENT_FRAMEWORK.SEED_LCL_BANNER_CONFIG('SILVER', 'GOLD');


-- =============================================================================
-- VERIFICATION SUMMARY
-- =============================================================================

USE DATABASE ATS_V3_TEST;

SELECT 'RENSPETS_PRODUCTS'       AS table_name,
       COUNT(*)                  AS total_rows,
       COUNT(DISTINCT UPC)       AS distinct_upcs,
       SUM(CASE WHEN PRODUCT_KEY LIKE 'ALTPROD-%' THEN 1 ELSE 0 END) AS composite_dupes
FROM BRONZE.RENSPETS_PRODUCTS

UNION ALL

SELECT 'DASHMART_PRODUCTS', COUNT(*), COUNT(DISTINCT UPC),
       SUM(CASE WHEN PRODUCT_KEY LIKE 'DM-DUP-%' THEN 1 ELSE 0 END)
FROM BRONZE.DASHMART_PRODUCTS

UNION ALL

SELECT 'LCL_PRODUCTS', COUNT(*), COUNT(DISTINCT UPC),
       SUM(CASE WHEN MOD(CHARINDEX('410',UPC),1) = 0 AND LEFT(UPC,3)='410' THEN 1 ELSE 0 END)
FROM BRONZE.LCL_PRODUCTS

UNION ALL

SELECT 'RENSPETS_SILVER', COUNT(*), COUNT(DISTINCT UPC), 0
FROM SILVER.RENSPETS_PRODUCTS_SILVER

UNION ALL

SELECT 'LCL_SILVER_DEDUPED', COUNT(*), COUNT(DISTINCT UPC||'|'||BANNER), 0
FROM SILVER.LCL_PRODUCTS_SILVER_DEDUPED

UNION ALL

SELECT 'LCL_GOLD_TOTAL (13 tables)', SUM(cnt), 0, 0
FROM (
    SELECT COUNT(*) AS cnt FROM GOLD.LCL_GOLD_SUPERSTORE
    UNION ALL SELECT COUNT(*) FROM GOLD.LCL_GOLD_NOFRILLS
    UNION ALL SELECT COUNT(*) FROM GOLD.LCL_GOLD_MAXI
    UNION ALL SELECT COUNT(*) FROM GOLD.LCL_GOLD_INDEPENDENT
    UNION ALL SELECT COUNT(*) FROM GOLD.LCL_GOLD_RASS
    UNION ALL SELECT COUNT(*) FROM GOLD.LCL_GOLD_ZEHRS
    UNION ALL SELECT COUNT(*) FROM GOLD.LCL_GOLD_LOBLAWS
    UNION ALL SELECT COUNT(*) FROM GOLD.LCL_GOLD_WHOLESALECLUB
    UNION ALL SELECT COUNT(*) FROM GOLD.LCL_GOLD_FORTINOS
    UNION ALL SELECT COUNT(*) FROM GOLD.LCL_GOLD_DOMINION
    UNION ALL SELECT COUNT(*) FROM GOLD.LCL_GOLD_PROVIGO
    UNION ALL SELECT COUNT(*) FROM GOLD.LCL_GOLD_VALUMART
) g

ORDER BY 1;
