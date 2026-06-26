-- =============================================================================
-- test_v3_scenarios.sql
-- Step-by-step test scenarios for ATS v3. Each scenario is self-contained
-- and targets a specific P0 fix. Run in order after test_v3_data.sql.
--
-- Database: MARKETBASKET_TEST
-- Prereq:   ATS v3 deployed to MARKETBASKET_TEST (run SETUP_ALL.sql first)
--           test_v3_data.sql executed successfully
--
-- Scenarios:
--   T-01  Deploy & bootstrap verification
--   T-02  DRY RUN mode (P0-2): DDL logged, nothing written
--   T-03  Safe output schema (P0-1): output goes to AGENT_FRAMEWORK_OUTPUT
--   T-04  Overwrite protection (P0-1): aborts when target has rows
--   T-05  Column injection (P0-3): exact columns in WORKFLOW_LOG prompts
--   T-06  Multi-banner validation (P0-4): VALIDATE_MULTI_BANNER for MarketBasket
--   T-07  Validator PK check (P0-5): pk_columns read from PLANNER_DECISIONS
-- =============================================================================

USE DATABASE MARKETBASKET_TEST;
USE SCHEMA AGENT_FRAMEWORK;

-- ─────────────────────────────────────────────────────────────────────────────
-- T-01: DEPLOY & BOOTSTRAP VERIFICATION
-- Confirms the framework deployed cleanly and discovered Bronze tables.
-- ─────────────────────────────────────────────────────────────────────────────

-- 1a. Verify framework objects exist
SELECT 'TABLES' AS object_type, COUNT(*) AS count
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'AGENT_FRAMEWORK'
UNION ALL
SELECT 'PROCEDURES', COUNT(*)
FROM INFORMATION_SCHEMA.PROCEDURES
WHERE PROCEDURE_SCHEMA = 'AGENT_FRAMEWORK'
UNION ALL
SELECT 'FUNCTIONS', COUNT(*)
FROM INFORMATION_SCHEMA.FUNCTIONS
WHERE FUNCTION_SCHEMA = 'AGENT_FRAMEWORK';
-- Expected: TABLES >= 8, PROCEDURES >= 10, FUNCTIONS >= 6

-- 1b. Bootstrap with Bronze schema
CALL AGENT_FRAMEWORK.BOOTSTRAP('BRONZE');
-- Expected: status=SUCCESS, bronze_tables=2 (SIMPLEMART_PRODUCTS, MARKETBASKET_PRODUCTS)

-- 1c. Confirm table discovery
SELECT bronze_table, bronze_schema, silver_table, silver_status
FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP
ORDER BY bronze_table;
-- Expected: 2 rows, silver_table=NULL, silver_status=NULL (not yet built)

-- 1d. Verify RESET_FRAMEWORK SP exists (was missing in v2)
CALL AGENT_FRAMEWORK.RESET_FRAMEWORK('YES');
-- Expected: status=RESET, lists cleared tables
-- Re-bootstrap after reset
CALL AGENT_FRAMEWORK.BOOTSTRAP('BRONZE');


-- ─────────────────────────────────────────────────────────────────────────────
-- T-02: DRY RUN MODE (P0-2)
-- Default behavior. DDL is generated and logged. Nothing is written.
-- ─────────────────────────────────────────────────────────────────────────────

-- 2a. Set context — dry_run=TRUE is the default, just making it explicit
CALL AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT(
    p_business_desc  => 'MarketBasket grocery retail. Bronze CDC feed from POS system.',
    p_data_domain    => 'Grocery Retail / Product Catalog',
    p_gold_goals     => 'Product availability, pricing analytics, banner performance.',
    p_constraints    => 'Exclude Ancillary category from Gold. Preserve bilingual names.',
    p_pipeline_type  => 'CTAS',
    p_output_schema  => 'AGENT_FRAMEWORK_OUTPUT',
    p_dry_run        => TRUE,
    p_overwrite_existing => FALSE
);
-- Expected: JSON confirming dry_run=true, output_schema=AGENT_FRAMEWORK_OUTPUT

-- 2b. Run the workflow on just SimpleMart (small, fast)
CALL AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW(
    'test',
    ARRAY_CONSTRUCT('MARKETBASKET_TEST.BRONZE.SIMPLEMART_PRODUCTS')
);
-- Expected: status=DRY_RUN_COMPLETE

-- 2c. Confirm AGENT_FRAMEWORK_OUTPUT schema is EMPTY (dry run never executes)
SELECT COUNT(*) AS tables_in_output
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'AGENT_FRAMEWORK_OUTPUT';
-- PASS if: tables_in_output = 0

-- 2d. Confirm DDL was logged
SELECT phase, status, LEFT(message, 200) AS message_preview
FROM AGENT_FRAMEWORK.WORKFLOW_LOG
WHERE status = 'DRY_RUN'
ORDER BY log_ts;
-- PASS if: rows returned with status=DRY_RUN and message starts with '[DRY RUN]'
-- The message should contain CREATE OR REPLACE TABLE AGENT_FRAMEWORK_OUTPUT.SIMPLEMART_PRODUCTS

-- 2e. Confirm SILVER schema is untouched
SELECT COUNT(*) AS silver_tables
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'SILVER'
  AND TABLE_NAME LIKE '%SIMPLEMART%';
-- PASS if: silver_tables = 0


-- ─────────────────────────────────────────────────────────────────────────────
-- T-03: SAFE OUTPUT SCHEMA (P0-1)
-- When dry_run=FALSE, output goes to AGENT_FRAMEWORK_OUTPUT — never SILVER/GOLD.
-- ─────────────────────────────────────────────────────────────────────────────

-- 3a. Reset framework state
CALL AGENT_FRAMEWORK.RESET_FRAMEWORK('YES');
CALL AGENT_FRAMEWORK.BOOTSTRAP('BRONZE');

-- 3b. Set context with dry_run=FALSE, explicit safe output schema
CALL AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT(
    p_business_desc  => 'MarketBasket grocery retail.',
    p_data_domain    => 'Grocery Retail / Product Catalog',
    p_output_schema  => 'AGENT_FRAMEWORK_OUTPUT',
    p_dry_run        => FALSE,
    p_overwrite_existing => FALSE
);

-- 3c. Run on SimpleMart
CALL AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW(
    'test',
    ARRAY_CONSTRUCT('MARKETBASKET_TEST.BRONZE.SIMPLEMART_PRODUCTS')
);
-- Expected: status=EXECUTED (not DRY_RUN_COMPLETE)

-- 3d. Confirm table was created in AGENT_FRAMEWORK_OUTPUT
SELECT TABLE_NAME, ROW_COUNT
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'AGENT_FRAMEWORK_OUTPUT'
ORDER BY TABLE_NAME;
-- PASS if: SIMPLEMART_PRODUCTS table exists with > 0 rows

-- 3e. Confirm SILVER schema is still untouched
SELECT COUNT(*) AS silver_tables
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'SILVER'
  AND TABLE_NAME LIKE '%SIMPLEMART%';
-- PASS if: silver_tables = 0 — v3 NEVER writes to SILVER by default

-- 3f. Confirm lineage map was updated
SELECT bronze_table, silver_schema, silver_status
FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP
WHERE UPPER(bronze_table) = 'SIMPLEMART_PRODUCTS';
-- PASS if: silver_schema = 'AGENT_FRAMEWORK_OUTPUT', silver_status = 'COMPLETE'


-- ─────────────────────────────────────────────────────────────────────────────
-- T-04: OVERWRITE PROTECTION (P0-1)
-- Executor aborts if target table exists with rows and overwrite_existing=FALSE.
-- Uses the pre-built SILVER.MARKETBASKET_PRODUCTS_SILVER from test_v3_data.sql.
-- ─────────────────────────────────────────────────────────────────────────────

-- 4a. Reset and re-bootstrap
CALL AGENT_FRAMEWORK.RESET_FRAMEWORK('YES');
CALL AGENT_FRAMEWORK.BOOTSTRAP('BRONZE');

-- 4b. Set output_schema to SILVER (where the pre-built table lives)
CALL AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT(
    p_business_desc  => 'Overwrite protection test.',
    p_output_schema  => 'SILVER',
    p_dry_run        => FALSE,
    p_overwrite_existing => FALSE  -- default: protect existing data
);

-- 4c. Run on MarketBasket — target SILVER.MARKETBASKET_PRODUCTS_SILVER already has ~39K rows
CALL AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW(
    'test',
    ARRAY_CONSTRUCT('MARKETBASKET_TEST.BRONZE.MARKETBASKET_PRODUCTS')
);

-- 4d. Confirm the executor ABORTED — did not overwrite
SELECT phase, status, LEFT(message, 300) AS message
FROM AGENT_FRAMEWORK.WORKFLOW_LOG
WHERE status IN ('ABORTED', 'OK', 'DRY_RUN')
ORDER BY log_ts;
-- PASS if: status=ABORTED with message containing 'TARGET_EXISTS_NO_OVERWRITE'
-- FAIL if: status=OK (would mean it overwrote the table)

-- 4e. Verify original Silver table is intact
SELECT COUNT(*) AS silver_rows FROM SILVER.MARKETBASKET_PRODUCTS_SILVER;
-- PASS if: row count matches pre-test value (~39,800)

-- 4f. Confirm overwrite_existing guard error
CALL AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT(
    p_overwrite_existing => TRUE,
    p_dry_run            => TRUE   -- should fail: can't combine overwrite=TRUE + dry_run=TRUE
);
-- PASS if: returns ERROR message about ambiguous state


-- ─────────────────────────────────────────────────────────────────────────────
-- T-05: COLUMN INJECTION / HALLUCINATION PREVENTION (P0-3)
-- Verifies the Executor prompt includes the exact column list from INFORMATION_SCHEMA.
-- ─────────────────────────────────────────────────────────────────────────────

-- 5a. Reset and run a dry-run to capture the prompt in the log
CALL AGENT_FRAMEWORK.RESET_FRAMEWORK('YES');
CALL AGENT_FRAMEWORK.BOOTSTRAP('BRONZE');

CALL AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT(
    p_dry_run => TRUE,
    p_output_schema => 'AGENT_FRAMEWORK_OUTPUT'
);

CALL AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW(
    'test',
    ARRAY_CONSTRUCT('MARKETBASKET_TEST.BRONZE.SIMPLEMART_PRODUCTS')
);

-- 5b. Inspect DRY_RUN log entry for column list evidence
SELECT message
FROM AGENT_FRAMEWORK.WORKFLOW_LOG
WHERE status = 'DRY_RUN'
LIMIT 1;
-- PASS if: generated SQL references actual column names from BRONZE.SIMPLEMART_PRODUCTS
-- (PRODUCT_ID, SKU, PRODUCT_NAME, CATEGORY, PRICE, COST, UPC, etc.)
-- FAIL if: SQL references invented columns like INGEST_DATE, OTHER_COLUMNS, PRODUCT_TITLE

-- 5c. Cross-reference against actual INFORMATION_SCHEMA columns
SELECT column_name, data_type, ordinal_position
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'BRONZE'
  AND TABLE_NAME = 'SIMPLEMART_PRODUCTS'
ORDER BY ordinal_position;
-- Use this as ground truth. Every column in the generated SQL should be in this list.


-- ─────────────────────────────────────────────────────────────────────────────
-- T-06: MULTI-BANNER VALIDATION (P0-4)
-- Tests VALIDATE_MULTI_BANNER against the pre-built Gold tables for MarketBasket.
-- The Gold tables exclude Ancillary category — validation must account for this.
-- ─────────────────────────────────────────────────────────────────────────────

-- 6a. Seed MarketBasket banner config
INSERT INTO AGENT_FRAMEWORK.PARTNER_BANNER_CONFIG
    (partner_name, bronze_table, silver_table, banner_column, banner_value,
     gold_table, excluded_categories, upc_threshold_pct, notes)
VALUES
    ('MARKETBASKET',
     'BRONZE.MARKETBASKET_PRODUCTS',
     'SILVER.MARKETBASKET_PRODUCTS_SILVER',
     'BANNER', 'standard',
     'GOLD.MARKETBASKET_STANDARD',
     'Ancillary', 3.3,
     'Standard format stores'),
    ('MARKETBASKET',
     'BRONZE.MARKETBASKET_PRODUCTS',
     'SILVER.MARKETBASKET_PRODUCTS_SILVER',
     'BANNER', 'express',
     'GOLD.MARKETBASKET_EXPRESS',
     'Ancillary', 3.3,
     'Express convenience format'),
    ('MARKETBASKET',
     'BRONZE.MARKETBASKET_PRODUCTS',
     'SILVER.MARKETBASKET_PRODUCTS_SILVER',
     'BANNER', 'premium',
     'GOLD.MARKETBASKET_PREMIUM',
     'Ancillary', 3.3,
     'Premium format stores');

-- 6b. Confirm config seeded correctly
SELECT partner_name, banner_value, gold_table, excluded_categories
FROM AGENT_FRAMEWORK.PARTNER_BANNER_CONFIG
WHERE partner_name = 'MARKETBASKET'
ORDER BY banner_value;
-- Expected: 3 rows — standard, express, premium

-- 6c. Run multi-banner validation
CALL AGENT_FRAMEWORK.VALIDATE_MULTI_BANNER('MARKETBASKET', 'MARKETBASKET_TEST');
-- PASS if:
--   total_banners = 3
--   pass_count    = 3
--   fail_count    = 0
-- Each banner result should show:
--   silver_rows:   ~13,300 (1/3 of ~39,800 Silver rows)
--   excluded_rows: ~1,900  (1/7 of banner rows = Ancillary)
--   expected_gold: ~11,400 (silver - excluded)
--   gold_rows:     ~11,400 (matching expected within 1% tolerance)
--   variance_pct:  <1.0

-- 6d. Test GET_BANNER_CONFIG function
SELECT AGENT_FRAMEWORK.GET_BANNER_CONFIG('MARKETBASKET');
-- Expected: ARRAY of 3 VARIANT objects with all config fields


-- ─────────────────────────────────────────────────────────────────────────────
-- T-07: VALIDATOR PK CHECK FROM PLANNER_DECISIONS (P0-5)
-- Confirms the Validator reads pk_columns from PLANNER_DECISIONS
-- instead of guessing the wrong column.
-- ─────────────────────────────────────────────────────────────────────────────

-- 7a. Reset and run a full workflow (dry_run=FALSE so Validator runs)
CALL AGENT_FRAMEWORK.RESET_FRAMEWORK('YES');
CALL AGENT_FRAMEWORK.BOOTSTRAP('BRONZE');

CALL AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT(
    p_dry_run            => FALSE,
    p_output_schema      => 'AGENT_FRAMEWORK_OUTPUT',
    p_overwrite_existing => TRUE  -- allow since AGENT_FRAMEWORK_OUTPUT was cleared by reset
);

CALL AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW(
    'test',
    ARRAY_CONSTRUCT('MARKETBASKET_TEST.BRONZE.SIMPLEMART_PRODUCTS')
);

-- 7b. Check what pk_columns the Planner identified
SELECT source_table, pk_columns, transformation_strategy
FROM AGENT_FRAMEWORK.PLANNER_DECISIONS
ORDER BY priority;
-- Expected: pk_columns = 'PRODUCT_ID' (or similar — the actual PK, not PRICE or other columns)

-- 7c. Check Validator output includes pk_columns (not a guess)
SELECT
    value:bronze_table::VARCHAR AS bronze_table,
    value:silver_table::VARCHAR AS silver_table,
    value:pk_columns::VARCHAR   AS pk_columns,
    value:passed::BOOLEAN       AS passed,
    value:variance_pct::FLOAT   AS variance_pct
FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS,
     LATERAL FLATTEN(input => validator_output:results)
ORDER BY bronze_table;
-- PASS if: pk_columns matches what PLANNER_DECISIONS.pk_columns shows (not NULL, not 'PRICE')


-- ─────────────────────────────────────────────────────────────────────────────
-- T-08: FULL RESULTS SUMMARY
-- Run after all scenarios to get a consolidated pass/fail view.
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
    'T-02 Dry Run: AGENT_FRAMEWORK_OUTPUT empty after dry run'          AS test,
    CASE WHEN (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES
               WHERE TABLE_SCHEMA = 'AGENT_FRAMEWORK_OUTPUT') = 0
         THEN 'PASS' ELSE 'FAIL' END AS result
UNION ALL
SELECT
    'T-03 Safe Output: SIMPLEMART in AGENT_FRAMEWORK_OUTPUT not SILVER',
    CASE WHEN (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES
               WHERE TABLE_SCHEMA = 'AGENT_FRAMEWORK_OUTPUT'
                 AND TABLE_NAME LIKE '%SIMPLEMART%') > 0
          AND (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES
               WHERE TABLE_SCHEMA = 'SILVER'
                 AND TABLE_NAME LIKE '%SIMPLEMART%') = 0
         THEN 'PASS' ELSE 'SEE T-03' END
UNION ALL
SELECT
    'T-04 Overwrite: ABORTED log entry exists',
    CASE WHEN (SELECT COUNT(*) FROM AGENT_FRAMEWORK.WORKFLOW_LOG
               WHERE status = 'ABORTED') > 0
         THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT
    'T-04 Overwrite: Silver row count preserved',
    CASE WHEN (SELECT COUNT(*) FROM SILVER.MARKETBASKET_PRODUCTS_SILVER) > 39000
         THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT
    'T-05 Columns: DRY_RUN log entries exist',
    CASE WHEN (SELECT COUNT(*) FROM AGENT_FRAMEWORK.WORKFLOW_LOG
               WHERE status = 'DRY_RUN') > 0
         THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT
    'T-06 Multi-Banner: 3 banners seeded',
    CASE WHEN (SELECT COUNT(*) FROM AGENT_FRAMEWORK.PARTNER_BANNER_CONFIG
               WHERE partner_name = 'MARKETBASKET') = 3
         THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT
    'T-07 PK Check: pk_columns populated in PLANNER_DECISIONS',
    CASE WHEN (SELECT COUNT(*) FROM AGENT_FRAMEWORK.PLANNER_DECISIONS
               WHERE pk_columns IS NOT NULL) > 0
         THEN 'PASS' ELSE 'NEEDS_FULL_RUN' END;
