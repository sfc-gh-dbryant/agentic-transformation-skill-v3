-- =============================================================================
-- SETUP_ALL.sql  [v3]
-- Full deployment for the Agentic Transformation Skill v3.
--
-- USAGE (Snow CLI / snowsql only):
--   This script uses !source directives — it CANNOT be pasted into Snowsight.
--
--   Recommended: use deploy.sh (which prepends the required SET variables):
--     ./setup/deploy.sh --connection MY_CONN --database MY_DB --bronze-schema RAW
--
--   Or with snowsql directly:
--     snowsql -c MY_CONN -D TARGET_DB=MY_DB -D BRONZE_SCHEMA=RAW -f SETUP_ALL.sql
--
--   NOTE: snow sql does NOT support !source. Use deploy.sh or snowsql.
--   To deploy via Snowsight, run each numbered file (00-11) individually in order.
--   See README.md for Snowsight step-by-step instructions.
--
-- DEPENDENCY ORDER (must run in this sequence):
--   00  Schema, MODEL_CONFIG, BOOTSTRAP, RESET_FRAMEWORK
--   01  Registry tables (TABLE_LINEAGE_MAP, PLANNER_DECISIONS, WORKFLOW_EXECUTIONS, WORKFLOW_LOG)
--   02  Schema contracts
--   03  Transformation directives
--   04a Discover schema SP
--   04b Planner SP          [v3: Cortex Search injection via CALL SEARCH_ATS_KNOWLEDGE]
--   04c Executor SP         [v3: dry_run, safe output_schema, cross-db column injection]
--   04d Validator SP        [v3: pk_columns from PLANNER_DECISIONS]
--   04e Reflector SP
--   04f Orchestrator SP
--   05  Gold builder SPs
--   06  Schema analyst SP
--   07  Pipeline context    [v3: output_schema, dry_run, overwrite_existing]
--   08  DCM export
--   09  Banner config       [v3 NEW: multi-banner support, VALIDATE_MULTI_BANNER]
--   10  Cortex Search       [v3 NEW: ATS_KNOWLEDGE_CORPUS view, ATS_KNOWLEDGE_SEARCH service, SEARCH_ATS_KNOWLEDGE SP]
--   11  Semantic View       [v3 NEW: ATS_PIPELINE_SEMANTICS for Cortex Analyst / Snowflake Intelligence]
-- =============================================================================

-- 00 — Schema, framework tables, MODEL_CONFIG, BOOTSTRAP, RESET_FRAMEWORK
!source 00_bootstrap.sql

-- 01 — TABLE_LINEAGE_MAP, PLANNER_DECISIONS, WORKFLOW_EXECUTIONS, WORKFLOW_LOG
!source 01_transformation_registry.sql

-- 02 — Schema Contracts (structural DDL rules for SILVER/GOLD layers)
!source 02_schema_contracts.sql

-- 03 — Transformation Directives (per-table business intent)
!source 03_directives.sql

-- 04 — Workflow Engine SPs
!source 04a_discover_schema.sql
!source 04b_planner.sql
!source 04c_executor.sql
!source 04d_validator.sql
!source 04e_reflector.sql
!source 04f_orchestrator.sql

-- 05 — Gold Builder SPs
!source 05_gold_builder.sql

-- 06 — Schema Analyst SP
!source 06_schema_analyst.sql

-- 07 — Pipeline Context (business intent + v3 safety config)
!source 07_pipeline_context.sql

-- 08 — DCM Export
!source 08_dcm_export.sql

-- 09 — Banner Config (v3 NEW: multi-banner partner support)
!source 09_banner_config.sql

-- 10 — Cortex Search knowledge index + SEARCH_ATS_KNOWLEDGE function (v3 NEW)
!source 10_cortex_search.sql

-- 11 — Semantic View for Snowflake Intelligence / Cortex Sense (v3 NEW)
!source 11_semantic_view.sql

-- 12 — Document Ingestion: stage, chunking SPs, ATS_KNOWLEDGE_CORPUS update (v3 NEW — B-01)
!source 12_document_ingestion.sql

-- Final: bootstrap with Bronze table inventory
USE DATABASE IDENTIFIER($TARGET_DB);
CALL AGENT_FRAMEWORK.BOOTSTRAP($BRONZE_SCHEMA);
