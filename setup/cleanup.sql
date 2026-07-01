-- =============================================================================
-- cleanup.sql  [v3]
-- Drops ALL objects created by the Agentic Transformation Skill v3.
-- Safe to run multiple times (IF EXISTS everywhere).
--
-- PRESERVES:
--   ATS_V3_TEST.BRONZE  — source test data, never touched
--   ATS_V4              — v4 database, out of scope
--
-- DROPS:
--   ATS_V3              — entire framework database (SPs, tables, stages,
--                         Streamlit app, Cortex Search service, semantic view)
--   ATS_V3_TEST.SILVER
--   ATS_V3_TEST.SILVER_STAGING
--   ATS_V3_TEST.GOLD
--
-- Usage:
--   snow sql -c YOUR_CONNECTION -f setup/cleanup.sql
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- ---------------------------------------------------------------------------
-- 1. Drop the framework database entirely
-- ---------------------------------------------------------------------------
DROP DATABASE IF EXISTS ATS_V3;

-- ---------------------------------------------------------------------------
-- 2. Drop pipeline output schemas from the test database
--    (leave BRONZE untouched)
-- ---------------------------------------------------------------------------
DROP SCHEMA IF EXISTS ATS_V3_TEST.SILVER CASCADE;
DROP SCHEMA IF EXISTS ATS_V3_TEST.SILVER_STAGING CASCADE;
DROP SCHEMA IF EXISTS ATS_V3_TEST.GOLD CASCADE;

-- ---------------------------------------------------------------------------
-- 3. Verify what remains in ATS_V3_TEST
-- ---------------------------------------------------------------------------
SHOW SCHEMAS IN DATABASE ATS_V3_TEST;

SELECT 'Cleanup complete. ATS_V3_TEST.BRONZE preserved. Ready for fresh deploy.' AS status;
