# ATS v4 Design Reference

**Database:** `ATS_V4` | **Schema:** `AGENT_FRAMEWORK`  
**Status:** Implemented and Tested  
**Last Updated:** June 2026

---

## Overview

ATS v4 is a hybrid agentic pipeline that transforms Bronze source tables into curated Silver and Gold layers using Snowflake Cortex Agents, SQL Scripting stored procedures, and a shared framework data layer. The pipeline runs in five sequential phases (Schema Analyst → Planner → Executor → Validator → Reflector), each backed by both a v3 SQL Scripting SP and a v4 Cortex Agent. The Orchestrator Agent coordinates execution.

**Object count:** 13 tables · 5 views · 1 semantic view · 1 Cortex Search service · 6 Cortex Agents · 35 tool SPs · 27 framework SPs

---

## Tables

### Configuration Tables

| Table | Setup File | Purpose |
|-------|-----------|---------|
| `MODEL_CONFIG` | `00_bootstrap.sql` | Single-row table. Stores the active Cortex model name and last validation timestamp. No SP hardcodes a model name — all read from here at runtime. |
| `PIPELINE_CONTEXT` | `07_pipeline_context.sql` | Single-row operational context. Captures: `output_schema` (target for all DDL output), `dry_run` flag (default TRUE — generates DDL but never executes), `overwrite_existing` flag, `pipeline_type` (CTAS or DYNAMIC_TABLE), `target_lag`, `gold_output_mode`, `brownfield_mode`, `conflict_fallback_schema`. Set once before each run via `SET_PIPELINE_CONTEXT`. |
| `SCHEMA_CONTRACTS` | `02_schema_contracts.sql` | Structural rules the LLM must follow when generating Silver/Gold DDL. Each row is a named rule with `rule_name`, `rule_value`, `rule_category`, `applies_to_layer`, `is_active`. Injected into Planner prompts at runtime. Editable via Streamlit Tab 2. Seeded by `SEED_DEFAULT_CONTRACTS`. |
| `TRANSFORMATION_DIRECTIVES` | `03_directives.sql` | Per-table business intent descriptions. Each row has a `source_table_pattern` (SQL LIKE match), `use_case`, `instructions`, `priority`, and `is_active`. Matched to Bronze table names at planning time and injected into Planner prompts. Editable via Streamlit Tab 3. |
| `PARTNER_BANNER_CONFIG` | `09_banner_config.sql` | Multi-banner partner routing table. Maps one Silver staging table to N Gold tables via `banner_column` filter. Supports banner merging (`merge_into_banner`), category exclusions (`excluded_categories`), and UPC thresholds (`upc_threshold_pct`). Used by `VALIDATE_MULTI_BANNER` and the Gold Builder. |

### Lineage & Runtime Tables

| Table | Setup File | Purpose |
|-------|-----------|---------|
| `TABLE_LINEAGE_MAP` | `01_transformation_registry.sql` | Single source of truth for Bronze → Silver → Gold coverage. One row per table per layer. Columns: `bronze_fqn`, `silver_fqn`, `gold_fqn`, `status`, `pipeline_type`, `created_at`, `updated_at`. Populated at bootstrap (Bronze entries), updated by Executor and Gold Builder on success. |
| `WORKFLOW_EXECUTIONS` | `01_transformation_registry.sql` | One row per workflow run. Tracks: `execution_id`, `status`, `current_phase`, phase timestamps (`schema_analyst_started_at`, `planner_started_at`, etc.), `tables_in_scope`, `tables_built`, `tables_failed`, `schema_analyst_completed_at`. Written by all phases. |
| `PLANNER_DECISIONS` | `01_transformation_registry.sql` | One row per table per execution. Stores the LLM's planning output: `bronze_fqn`, `silver_fqn`, `transformation_strategy`, `pk_columns`, `scd_type`, `rationale`, `confidence_score`. Read by Validator (for PK columns) and Reflector. |
| `SCHEMA_RELATIONSHIPS` | `06_schema_analyst.sql` | FK and entity-reference relationships discovered by the Schema Analyst phase. Columns: `execution_id`, `source_table`, `target_table`, `relationship_type`, `source_column`, `target_column`, `confidence`, `reasoning`. Injected into Planner prompts per-table. |
| `WORKFLOW_LOG` | `01_transformation_registry.sql` | Operational event log for debugging. One row per event: `execution_id`, `phase`, `table_name`, `status` (OK / WARN / ERROR / INFO), `message`, `logged_at`. Not surfaced in Streamlit by default. Used by Reflector as raw input. |
| `WORKFLOW_LEARNINGS` | `01_transformation_registry.sql` | The system's persistent memory. Written by the Reflector phase after each run. Columns: `learning_id`, `execution_id`, `learning_type`, `content`, `confidence`, `applies_to_pattern`, `created_at`. High-confidence learnings are retrieved via Cortex Search and injected into future Planner prompts. Survives `CLEAR_WORKFLOW_HISTORY`. |
| `DOCUMENT_CONTEXT_ITEMS` | `12_document_ingestion.sql` | Backing table for RAG document chunks. Each row is a chunk from an uploaded PDF/text document: `doc_name`, `chunk_index`, `chunk_text`, `source_type`, `uploaded_at`. Included in `ATS_KNOWLEDGE_CORPUS` so Cortex Search automatically indexes it. Survives `CLEAR_WORKFLOW_HISTORY`. |
| `WORKFLOW_COST_ATTRIBUTION` | `08_cost_attribution.sql` | Cost tracking per execution. Populated by `CAPTURE_WORKFLOW_COST` (not by the pipeline SPs). Columns: `execution_id`, `warehouse_credits`, `cortex_credits`, `cortex_tokens`, `total_credits`, `query_count`, `llm_call_count`, `retry_llm_calls`, `cost_per_table`, `tables_built`, `phase_breakdown` (VARIANT), `cortex_data_lag`. Note: Cortex credit data has up to 45-minute delay from `CORTEX_FUNCTIONS_USAGE_HISTORY`. |

---

## Views

| View | Setup File | Purpose |
|------|-----------|---------|
| `ACTIVE_DIRECTIVES` | `03_directives.sql` | Filtered view of `TRANSFORMATION_DIRECTIVES` where `is_active = TRUE`. Used by `ATS_TOOL_GET_DIRECTIVES` so inactive directives are never injected into prompts. |
| `COVERAGE_SUMMARY` | `01_transformation_registry.sql` | Aggregated pipeline coverage metrics. Shows counts of Bronze tables with and without Silver/Gold counterparts. Used by Streamlit pipeline health section. |
| `SILVER_GAPS` | `01_transformation_registry.sql` | Bronze tables in `TABLE_LINEAGE_MAP` that have no Silver table yet (`silver_fqn IS NULL` or status not COMPLETE). Used by `ATS_TOOL_LIST_SILVER_GAPS` to scope each run. |
| `GOLD_GAPS` | `01_transformation_registry.sql` | Silver tables in `TABLE_LINEAGE_MAP` that have no Gold table yet. Used by `BUILD_GOLD_FOR_NEW_TABLES` to identify build targets. |
| `ATS_KNOWLEDGE_CORPUS` | `10_cortex_search.sql` + `12_document_ingestion.sql` | UNION ALL backing view for Cortex Search. Combines three knowledge sources into a single `content` column: `WORKFLOW_LEARNINGS` (type: `learning`), `PLANNER_DECISIONS` (type: `decision`), `SCHEMA_RELATIONSHIPS` (type: `relationship`), `DOCUMENT_CONTEXT_ITEMS` (type: `document`). Required because Cortex Search indexes a single source. |

---

## Semantic View

| Object | Setup File | Purpose |
|--------|-----------|---------|
| `ATS_PIPELINE_SEMANTICS` | `11_semantic_view.sql` | Cortex Analyst semantic view over the ATS framework tables. Generated via `SYSTEM$CORTEX_ANALYST_FAST_GENERATION`. Enables natural language queries over pipeline state (e.g., "which tables failed last run?", "what is the average retry count?"). Also the input the framework will consume when Cortex Sense reaches GA. |

---

## Cortex Search Service

| Object | Setup File | Purpose |
|--------|-----------|---------|
| `ATS_KNOWLEDGE_SEARCH` | `10_cortex_search.sql` | Indexes `ATS_KNOWLEDGE_CORPUS` for semantic retrieval. Called by `SEARCH_ATS_KNOWLEDGE()` which the Planner invokes before each LLM batch to retrieve similar prior decisions, reducing hallucination and retry loops. Refreshes approximately every hour. |

---

## Cortex Agents

| Agent | Setup File | Phase | Tools |
|-------|-----------|-------|-------|
| `ATS_SCHEMA_ANALYST_AGENT` | `v4_agents.sql` | Phase 1 | `discover_schema`, `sample_data`, `search_relationships`, `list_tables` |
| `ATS_PLANNER_AGENT` | `v4_agents.sql` | Phase 2 | `get_pipeline_context`, `get_contracts`, `get_directives`, `get_schema_relationships`, `search_prior_decisions`, `get_gold_schemas` |
| `ATS_EXECUTOR_AGENT` | `v4_agents.sql` | Phase 3 | `get_columns`, `execute_ddl`, `validate_column`, `check_table_exists`, `get_sample_rows` |
| `ATS_VALIDATOR_AGENT` | `v4_agents.sql` | Phase 4 | `count_rows`, `check_pk_uniqueness`, `compare_counts`, `query_sample`, `get_planner_decision` |
| `ATS_REFLECTOR_AGENT` | `v4_agents.sql` | Phase 5 | `search_learnings`, `save_learning`, `get_workflow_log`, `get_executor_output` |
| `ATS_ORCHESTRATOR_AGENT` | `v4_agents.sql` | Coordinator | `create_execution`, `get_workflow_status`, `update_workflow_status`, `log_workflow_event`, `list_silver_gaps`, `run_schema_analyst` (v3 bridge), `run_planner`, `run_executor`, `run_validator`, `run_reflector` |

### Agent Descriptions

**`ATS_SCHEMA_ANALYST_AGENT`**  
Discovers FK and entity-reference relationships across all Bronze tables before planning begins. Takes a list of table FQNs, inspects column names and sample data, and infers join relationships including non-obvious name mismatches. Writes results to `SCHEMA_RELATIONSHIPS`. The v3 SP equivalent is `WORKFLOW_SCHEMA_ANALYST`.

**`ATS_PLANNER_AGENT`**  
Decides the transformation strategy, primary key columns, and SCD type for each Bronze table. Reads pipeline context, schema contracts, per-table directives, discovered relationships, and prior decisions from Cortex Search. Writes one `PLANNER_DECISIONS` row per table. The v3 SP equivalent is `WORKFLOW_PLANNER`.

**`ATS_EXECUTOR_AGENT`**  
Generates and executes Silver-layer DDL with tool-grounded column validation. Uses `get_columns` to retrieve the exact column list from `INFORMATION_SCHEMA` before generating any DDL, preventing hallucinated column names. Supports CTAS and Dynamic Table pipeline types. The v3 SP equivalent is `WORKFLOW_EXECUTOR` (which includes a 3-retry self-correction loop with a CONFLICT_REDIRECTED hallucination guard).

**`ATS_VALIDATOR_AGENT`**  
Verifies Silver table quality post-build. Performs: row count parity (Bronze vs Silver), PK uniqueness check using authoritative PK columns from `PLANNER_DECISIONS`, SCD2-aware row count (IS_CURRENT = TRUE only), and spot-check sample queries. Writes PASS/FAIL results to `WORKFLOW_LOG`. The v3 SP equivalent is `WORKFLOW_VALIDATOR`.

**`ATS_REFLECTOR_AGENT`**  
Post-mortem LLM analysis of each completed run. Reads `WORKFLOW_LOG` and `PLANNER_DECISIONS`, extracts generalizable learnings, deduplicates against existing learnings via Cortex Search, and saves new learnings to `WORKFLOW_LEARNINGS`. Always runs regardless of Executor/Validator outcome. The v3 SP equivalent is `WORKFLOW_REFLECTOR`.

**`ATS_ORCHESTRATOR_AGENT`**  
Coordinates the five sub-agents in sequence. Creates the execution record, checks `SILVER_GAPS` to determine scope, calls each phase agent via bridge tools (which call the v3 SPs), and tracks overall status. During the v3→v4 transition, the bridge tools allow the Orchestrator to chain phases while each sub-agent is validated independently.

---

## Tool Stored Procedures

All tool SPs follow the same contract: named input parameters matching the Cortex Agent JSON schema, VARCHAR (JSON) return value that the agent reads as reasoning context. Naming convention: `ATS_TOOL_<VERB>_<NOUN>`.

### Schema Analyst Tools

| Procedure | Parameters | Purpose |
|-----------|-----------|---------|
| `ATS_TOOL_DISCOVER_SCHEMA` | `fqn VARCHAR` | Returns all columns (name, type, nullable) for a table from INFORMATION_SCHEMA. Used by Schema Analyst to understand each table before inferring relationships. |
| `ATS_TOOL_SAMPLE_DATA` | `fqn VARCHAR, n INTEGER` | Returns N sample rows as JSON. Used by Schema Analyst to detect value patterns that imply FK relationships. |
| `ATS_TOOL_SEARCH_RELATIONSHIPS` | `query VARCHAR` | Semantic search over `SCHEMA_RELATIONSHIPS` via Cortex Search. Returns previously discovered relationships relevant to the query. |
| `ATS_TOOL_LIST_TABLES` | `db VARCHAR, schema_name VARCHAR` | Lists all tables in a given database.schema. Used to enumerate the full scope before schema discovery. |

### Planner Tools

| Procedure | Parameters | Purpose |
|-----------|-----------|---------|
| `ATS_TOOL_GET_PIPELINE_CONTEXT` | _(none)_ | Returns current `PIPELINE_CONTEXT` row as JSON. Planner reads output schema, dry_run mode, pipeline type, and gold output mode before making decisions. |
| `ATS_TOOL_GET_CONTRACTS` | `layer VARCHAR` | Returns all active schema contracts for Silver or Gold layer. Planner injects these as hard rules into its DDL generation strategy. |
| `ATS_TOOL_GET_DIRECTIVES` | `table_pattern VARCHAR` | Returns transformation directives matching the Bronze table name via LIKE pattern. Planner uses these as per-table business intent instructions. |
| `ATS_TOOL_GET_SCHEMA_RELATIONSHIPS` | `execution_id VARCHAR` | Returns all relationships discovered by the Schema Analyst for this execution. Planner uses these to decide join strategies. |
| `ATS_TOOL_SEARCH_PRIOR_DECISIONS` | `query VARCHAR` | Semantic search over `PLANNER_DECISIONS` via `SEARCH_ATS_KNOWLEDGE`. Retrieves similar past decisions to reduce hallucination and reuse proven strategies. |
| `ATS_TOOL_GET_GOLD_SCHEMAS` | _(none)_ | Returns known Gold schema names from `TABLE_LINEAGE_MAP`. Planner uses this to target consistent output schemas. |

### Executor Tools

| Procedure | Parameters | Purpose |
|-----------|-----------|---------|
| `ATS_TOOL_GET_COLUMNS` | `fqn VARCHAR` | Returns the exact column list for a Bronze table from INFORMATION_SCHEMA. **Critical hallucination guard** — Executor must call this before generating any SELECT statement to ground column names. |
| `ATS_TOOL_EXECUTE_DDL` | `ddl VARCHAR, target_fqn VARCHAR` | Executes a DDL statement against Snowflake. Checks dry_run and overwrite_existing flags from PIPELINE_CONTEXT before executing. Writes result to WORKFLOW_LOG and updates TABLE_LINEAGE_MAP on success. |
| `ATS_TOOL_VALIDATE_COLUMN` | `fqn VARCHAR, column_name VARCHAR` | Verifies a column exists in a table before the DDL is submitted. Returns EXISTS or NOT_FOUND. Used by Executor to self-check generated column references. |
| `ATS_TOOL_CHECK_TABLE_EXISTS` | `fqn VARCHAR` | Returns whether a fully-qualified table already exists. Used to determine if brownfield skip or conflict redirect logic applies. |
| `ATS_TOOL_GET_SAMPLE_ROWS` | `fqn VARCHAR, n INTEGER` | Returns N sample rows from a Silver table post-build. Used by Executor for inline spot-check verification. |

### Validator Tools

| Procedure | Parameters | Purpose |
|-----------|-----------|---------|
| `ATS_TOOL_COUNT_ROWS` | `fqn VARCHAR` | Returns row count for a table. Used to compare Bronze source vs Silver target. |
| `ATS_TOOL_CHECK_PK_UNIQUENESS` | `fqn VARCHAR, pk_columns VARCHAR` | Counts duplicate PK combinations in a Silver table. Returns count of non-unique rows. Uses PK columns from `PLANNER_DECISIONS` — not guessed by the Validator. |
| `ATS_TOOL_COMPARE_COUNTS` | `bronze_fqn VARCHAR, silver_fqn VARCHAR` | Returns Bronze count, Silver count, and delta. SCD2-aware: if Silver has IS_CURRENT column, compares only IS_CURRENT=TRUE rows. |
| `ATS_TOOL_QUERY_SAMPLE` | `fqn VARCHAR, where_clause VARCHAR` | Executes a filtered sample query on a Silver table. Used for spot-check validation of specific row conditions. |
| `ATS_TOOL_SAVE_PLANNER_DECISION` | `execution_id, bronze_fqn, silver_fqn, strategy, pk_columns, scd_type, rationale, confidence` | Writes or updates a `PLANNER_DECISIONS` row. Used at the end of the Planner phase to persist per-table decisions for downstream phases. |
| `ATS_TOOL_GET_PLANNER_DECISION` | `execution_id VARCHAR, bronze_fqn VARCHAR` | Retrieves the Planner's decision for a specific table. Used by Validator to get authoritative PK columns without re-deriving them. |

### Reflector Tools

| Procedure | Parameters | Purpose |
|-----------|-----------|---------|
| `ATS_TOOL_SEARCH_LEARNINGS` | `query VARCHAR` | Semantic search over `WORKFLOW_LEARNINGS` via Cortex Search. Reflector uses this to deduplicate before saving a new learning. |
| `ATS_TOOL_SAVE_LEARNING` | `execution_id, learning_type, content, confidence, applies_to_pattern` | Writes a new row to `WORKFLOW_LEARNINGS`. Called by Reflector for each generalizable learning extracted from the run. |
| `ATS_TOOL_GET_WORKFLOW_LOG` | `execution_id VARCHAR` | Returns all WORKFLOW_LOG entries for an execution. Reflector uses this as the raw input for its post-mortem analysis. |
| `ATS_TOOL_GET_EXECUTOR_OUTPUT` | `execution_id VARCHAR` | Returns Executor-phase log entries (status, message, table) for an execution. Focused view used by Reflector to understand what succeeded and failed. |

### Orchestrator Tools

| Procedure | Parameters | Purpose |
|-----------|-----------|---------|
| `ATS_TOOL_CREATE_EXECUTION` | `execution_label VARCHAR` | Creates a new row in `WORKFLOW_EXECUTIONS` and returns the generated `execution_id`. Called by Orchestrator at the start of every run. |
| `ATS_TOOL_GET_WORKFLOW_STATUS` | `execution_id VARCHAR` | Returns current status and phase from `WORKFLOW_EXECUTIONS`. Used by Orchestrator to check whether to proceed to the next phase. |
| `ATS_TOOL_UPDATE_WORKFLOW_STATUS` | `execution_id, status, phase` | Updates `WORKFLOW_EXECUTIONS` status and current_phase. Called at each phase transition. |
| `ATS_TOOL_LOG_WORKFLOW_EVENT` | `execution_id, phase, table_name, status, message` | Writes a row to `WORKFLOW_LOG`. Orchestrator uses this to record phase-level events; individual SPs use it for table-level events. |
| `ATS_TOOL_LIST_SILVER_GAPS` | _(none)_ | Returns Bronze tables with no Silver counterpart from `SILVER_GAPS` view. Orchestrator uses this to determine the tables in scope for the current run. |
| `ATS_TOOL_RUN_SCHEMA_ANALYST` | `execution_id VARCHAR` | **v3 bridge.** Calls `WORKFLOW_SCHEMA_ANALYST` SP. Allows Orchestrator Agent to invoke the phase while the Schema Analyst Agent is being validated. |
| `ATS_TOOL_RUN_PLANNER` | `execution_id VARCHAR` | **v3 bridge.** Calls `WORKFLOW_PLANNER` SP. |
| `ATS_TOOL_RUN_EXECUTOR` | `execution_id VARCHAR` | **v3 bridge.** Calls `WORKFLOW_EXECUTOR` SP. |
| `ATS_TOOL_RUN_VALIDATOR` | `execution_id VARCHAR` | **v3 bridge.** Calls `WORKFLOW_VALIDATOR` SP. |
| `ATS_TOOL_RUN_REFLECTOR` | `execution_id VARCHAR` | **v3 bridge.** Calls `WORKFLOW_REFLECTOR` SP. |

---

## Framework Stored Procedures

### Pipeline Orchestration

| Procedure | Setup File | Signature | Purpose |
|-----------|-----------|-----------|---------|
| `RUN_AGENTIC_WORKFLOW` | `04f_orchestrator.sql` | `(execution_label VARCHAR DEFAULT NULL)` | Chains all five phases in sequence: Schema Analyst → Planner → Executor → Validator → Reflector. Used for CLI or Task-scheduled runs. Streamlit calls each phase SP individually for per-phase status display. |
| `WORKFLOW_SCHEMA_ANALYST` | `06_schema_analyst.sql` | `(execution_id VARCHAR)` | Phase 1 SP. Single LLM call across all tables in scope. Discovers FK and entity-reference relationships including non-obvious name mismatches. Python SP (not SQL Scripting) to support cross-database INFORMATION_SCHEMA queries per table. Writes to `SCHEMA_RELATIONSHIPS`. |
| `WORKFLOW_PLANNER` | `04b_planner.sql` | `(execution_id VARCHAR)` | Phase 2 SP. Per-table LLM call to decide transformation strategy, PK columns, and SCD type. Injects contracts, directives, relationships, and prior decisions from Cortex Search. Writes one `PLANNER_DECISIONS` row per table. |
| `WORKFLOW_EXECUTOR` | `04c_executor.sql` | `(execution_id VARCHAR)` | Phase 3 SP. Generates Silver DDL via 3-retry self-correcting loop. Reads exact column list from INFORMATION_SCHEMA before each LLM call. Includes CONFLICT_REDIRECTED hallucination guard. Respects dry_run and overwrite_existing from PIPELINE_CONTEXT. Writes OK/ERROR entries to WORKFLOW_LOG. |
| `WORKFLOW_VALIDATOR` | `04d_validator.sql` | `(execution_id VARCHAR)` | Phase 4 SP. Row count parity checks for all Silver tables built in this execution. SCD2-aware (checks IS_CURRENT=TRUE rows when present). Reads PK columns from PLANNER_DECISIONS. Cross-database INFORMATION_SCHEMA for SCD2 column detection. |
| `WORKFLOW_REFLECTOR` | `04e_reflector.sql` | `(execution_id VARCHAR)` | Phase 5 SP. LLM post-mortem. Reads WORKFLOW_LOG and PLANNER_DECISIONS, extracts learnings, MERGEs into WORKFLOW_LEARNINGS. Always runs regardless of prior phase outcomes. |

### Initialization & Configuration

| Procedure | Setup File | Signature | Purpose |
|-----------|-----------|-----------|---------|
| `BOOTSTRAP` | `00_bootstrap.sql` | `(bronze_sources VARCHAR)` | One-call initialization. Validates the active Cortex model, discovers Bronze tables, seeds default contracts and directives. `bronze_sources` accepts plain schema names, fully-qualified `DB.SCHEMA`, or comma-separated multi-source. |
| `SET_PIPELINE_CONTEXT` | `07_pipeline_context.sql` | `(output_schema, dry_run, overwrite_existing, pipeline_type, target_lag, gold_output_mode, brownfield_mode, conflict_fallback_schema)` | Updates PIPELINE_CONTEXT with run configuration. Must be called before each workflow run. Streamlit Pipeline tab calls this before triggering any phase. |
| `SET_BROWNFIELD_MODE` | `07_pipeline_context.sql` | `(enabled BOOLEAN)` | Convenience wrapper to toggle brownfield_mode in PIPELINE_CONTEXT. When TRUE, Executor skips tables where a Silver table already exists instead of aborting. |
| `SET_CONFLICT_FALLBACK_SCHEMA` | `07_pipeline_context.sql` | `(schema_name VARCHAR)` | Sets the conflict_fallback_schema in PIPELINE_CONTEXT. When a target slot is occupied by a VIEW, DYNAMIC TABLE, or empty table, Executor redirects output to this schema. |
| `VALIDATE_MODEL` | `00_bootstrap.sql` | `(test_model VARCHAR DEFAULT NULL)` | Tests a Cortex model with a lightweight prompt and updates MODEL_CONFIG. If test_model is NULL, tries the priority list and picks the first that works. Exposed in Streamlit Tab 1 "Re-validate Model". |
| `SEED_DEFAULT_CONTRACTS` | `02_schema_contracts.sql` | _(none)_ | Seeds SCHEMA_CONTRACTS with sensible structural defaults for Silver/Gold (surrogate keys, audit columns, naming conventions). Called by BOOTSTRAP when the table is empty. |
| `SEED_DEFAULT_DIRECTIVES` | `03_directives.sql` | _(none)_ | Seeds TRANSFORMATION_DIRECTIVES with generic defaults that work across most Bronze schemas. SA/customer replaces these with table-specific directives as they understand their data. |
| `SEED_LCL_BANNER_CONFIG` | `09_banner_config.sql` | _(none)_ | Seeds PARTNER_BANNER_CONFIG with LCL V2 configuration: 14 banners, 13 Gold tables, banner routing, and exclusion categories. Reference implementation for multi-banner partners. |

### Maintenance & Utilities

| Procedure | Setup File | Signature | Purpose |
|-----------|-----------|-----------|---------|
| `RESET_FRAMEWORK` | `00_bootstrap.sql` | `(confirm VARCHAR DEFAULT NULL)` | Full reset. Clears all runtime workflow data (executions, log, decisions, relationships, lineage). Preserves config tables (contracts, directives, model_config). Requires confirm='YES'. |
| `CLEAR_WORKFLOW_HISTORY` | `00_bootstrap.sql` | _(none)_ | Soft reset. Removes run history and planner decisions without touching TABLE_LINEAGE_MAP, contracts, directives, or learnings. Safe to call between demo runs. |
| `CAPTURE_WORKFLOW_COST` | `08_cost_attribution.sql` | `(execution_id VARCHAR)` | Standalone cost attribution SP. Queries `INFORMATION_SCHEMA.QUERY_HISTORY` for near-real-time warehouse credits, `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY` for Cortex credits (up to 45-min delay), and WORKFLOW_EXECUTIONS timestamps for phase durations. MERGEs into WORKFLOW_COST_ATTRIBUTION. Re-runnable at any time; not wired into the pipeline. |
| `DISCOVER_SCHEMA` | `04a_discover_schema.sql` | `(table_fqn VARCHAR)` | Inspects a table's columns via INFORMATION_SCHEMA and returns a formatted JSON description for LLM context. Utility called by Schema Analyst and standalone exploratory queries. |

### Schema Analysis

| Procedure | Setup File | Signature | Purpose |
|-----------|-----------|-----------|---------|
| `WORKFLOW_SCHEMA_ANALYST` | `06_schema_analyst.sql` | `(execution_id VARCHAR)` | See Pipeline Orchestration above. |

### Gold Layer

| Procedure | Setup File | Signature | Purpose |
|-----------|-----------|-----------|---------|
| `GOLD_AGENTIC_EXECUTOR` | `05_gold_builder.sql` | `(gold_ddl VARCHAR, source_silver_table VARCHAR)` | Executes a Gold DDL statement with up to 3 LLM self-correction retries. Supports multi-statement DDL (CREATE TABLE + ALTER TABLE CLUSTER BY). Updates TABLE_LINEAGE_MAP on success. Python SP. |
| `BUILD_GOLD_FOR_NEW_TABLES` | `05_gold_builder.sql` | `(dry_run BOOLEAN DEFAULT TRUE)` | Scans GOLD_GAPS, queries INFORMATION_SCHEMA for real Silver column lists, generates Gold DDL via LLM with 3-retry self-correction. dry_run=TRUE returns proposals without executing (Streamlit review mode). Python SP. |
| `EXPORT_DCM_PROJECT` | `08_dcm_export.sql` | `(output_stage VARCHAR)` | Generates a DCM project (DEFINE statements + manifest.yml) from all finalized Gold tables in TABLE_LINEAGE_MAP. Writes files to the specified stage path for version-controlled schema governance. |
| `GENERATE_DCM_PROJECT` | `08_dcm_export.sql` | `(output_stage VARCHAR)` | Generates a DCM project with infrastructure DEFINE blocks including schema definitions, access control grants, and managed objects. Companion to EXPORT_DCM_PROJECT for full project generation. |

### Document Ingestion (RAG)

| Procedure | Setup File | Signature | Purpose |
|-----------|-----------|-----------|---------|
| `INGEST_DOCUMENT_FROM_STAGE` | `12_document_ingestion.sql` | `(stage_path VARCHAR, doc_name VARCHAR)` | Reads a file from `@DOCUMENT_STAGE` (PDF or text), extracts text via `AI_PARSE_DOCUMENT`, chunks it, and inserts into `DOCUMENT_CONTEXT_ITEMS`. Cortex Search picks up the new chunks on its next refresh (~1 hour). |
| `INGEST_DOCUMENT_TEXT` | `12_document_ingestion.sql` | `(doc_name VARCHAR, text VARCHAR)` | Ingests raw text directly (no stage required). Chunks and inserts into `DOCUMENT_CONTEXT_ITEMS`. Used for programmatic document injection. |
| `LIST_DOCUMENTS` | `12_document_ingestion.sql` | _(none)_ | Returns all indexed documents with chunk counts and upload timestamps. Used by Streamlit document management panel. |
| `REMOVE_DOCUMENT` | `12_document_ingestion.sql` | `(doc_name VARCHAR)` | Deletes all chunks for a named document from `DOCUMENT_CONTEXT_ITEMS`. |
| `SEARCH_ATS_KNOWLEDGE` | `10_cortex_search.sql` | `(query VARCHAR, limit INTEGER DEFAULT 5)` | Calls the `ATS_KNOWLEDGE_SEARCH` Cortex Search service. Returns the top-N semantically relevant knowledge items (learnings, decisions, relationships, documents) for a query. Called by `ATS_TOOL_SEARCH_PRIOR_DECISIONS` and `ATS_TOOL_SEARCH_LEARNINGS`. |

### Multi-Banner Validation

| Procedure | Setup File | Signature | Purpose |
|-----------|-----------|-----------|---------|
| `VALIDATE_MULTI_BANNER` | `09_banner_config.sql` | `(partner_name VARCHAR)` | Validates all Gold tables for a multi-banner partner against their corresponding Silver subsets. Accounts for banner filters, category exclusions, and merge-into routing. Python SP for maintainability. |
| `VALIDATE_MODEL` | `00_bootstrap.sql` | See above | |

---

## Scalar Functions (non-SP)

These are SQL UDFs used inline by SPs and prompts — not agent tools.

| Function | Setup File | Purpose |
|----------|-----------|---------|
| `PIPELINE_CONTEXT_AS_PROMPT()` | `07_pipeline_context.sql` | Returns PIPELINE_CONTEXT formatted as a natural-language block for injection into LLM prompts. |
| `PIPELINE_TYPE()` | `07_pipeline_context.sql` | Returns current pipeline_type ('CTAS' or 'DYNAMIC_TABLE'). Shorthand read for SPs. |
| `TARGET_LAG()` | `07_pipeline_context.sql` | Returns current target_lag value. Shorthand read for SPs. |
| `OUTPUT_SCHEMA()` | `07_pipeline_context.sql` | Returns current output_schema. Shorthand read for SPs. |
| `CONTRACTS_AS_PROMPT_CONTEXT(layer)` | `02_schema_contracts.sql` | Returns active contracts for a layer formatted for LLM prompt injection. |
| `DIRECTIVES_FOR_TABLE(table_name)` | `03_directives.sql` | Returns formatted directives matching a Bronze table name via LIKE pattern. |
| `GET_BANNER_CONFIG(partner_name)` | `09_banner_config.sql` | Returns all active banner entries for a partner as a JSON ARRAY. |

---

## Stages

| Stage | Setup File | Purpose |
|-------|-----------|---------|
| `AGENT_STAGE` | `00_bootstrap.sql` | Internal stage for Streamlit app deployment (`snowflake.yml`, `streamlit_app_v4.py`). |
| `DOCUMENT_STAGE` | `12_document_ingestion.sql` | Internal stage for uploaded documents (PDFs, text files) before ingestion into `DOCUMENT_CONTEXT_ITEMS`. |
| `DCM_OUTPUT` | `08_dcm_export.sql` | Internal stage where `EXPORT_DCM_PROJECT` and `GENERATE_DCM_PROJECT` write DCM manifest and DEFINE files. |

---

## Setup File Order

Files must be deployed in this order. All SQL Scripting SPs (`04a`–`04f`) must be deployed via Python connector, not `snow sql -f`, due to a Snow CLI parser limitation with `||` concatenation inside `$$` blocks.

```
00_bootstrap.sql              Schema, MODEL_CONFIG, VALIDATE_MODEL, RESET_FRAMEWORK, CLEAR_WORKFLOW_HISTORY, BOOTSTRAP
01_transformation_registry.sql TABLE_LINEAGE_MAP, WORKFLOW_EXECUTIONS, PLANNER_DECISIONS, WORKFLOW_LEARNINGS, WORKFLOW_LOG, COVERAGE_SUMMARY, SILVER_GAPS, GOLD_GAPS
02_schema_contracts.sql       SCHEMA_CONTRACTS, SEED_DEFAULT_CONTRACTS, CONTRACTS_AS_PROMPT_CONTEXT()
03_directives.sql             TRANSFORMATION_DIRECTIVES, ACTIVE_DIRECTIVES, SEED_DEFAULT_DIRECTIVES, DIRECTIVES_FOR_TABLE()
04a_discover_schema.sql       DISCOVER_SCHEMA
04b_planner.sql               WORKFLOW_PLANNER
04c_executor.sql              WORKFLOW_EXECUTOR
04d_validator.sql             WORKFLOW_VALIDATOR
04e_reflector.sql             WORKFLOW_REFLECTOR
04f_orchestrator.sql          RUN_AGENTIC_WORKFLOW
05_gold_builder.sql           GOLD_AGENTIC_EXECUTOR, BUILD_GOLD_FOR_NEW_TABLES, EXPORT_DCM_PROJECT
06_schema_analyst.sql         SCHEMA_RELATIONSHIPS, WORKFLOW_SCHEMA_ANALYST
07_pipeline_context.sql       PIPELINE_CONTEXT, SET_PIPELINE_CONTEXT, SET_BROWNFIELD_MODE, SET_CONFLICT_FALLBACK_SCHEMA, helper UDFs
08_cost_attribution.sql       WORKFLOW_COST_ATTRIBUTION, CAPTURE_WORKFLOW_COST
08_dcm_export.sql             DCM_OUTPUT stage, GENERATE_DCM_PROJECT
09_banner_config.sql          PARTNER_BANNER_CONFIG, GET_BANNER_CONFIG(), VALIDATE_MULTI_BANNER, SEED_LCL_BANNER_CONFIG
10_cortex_search.sql          ATS_KNOWLEDGE_CORPUS (initial), ATS_KNOWLEDGE_SEARCH, SEARCH_ATS_KNOWLEDGE
11_semantic_view.sql          ATS_PIPELINE_SEMANTICS
12_document_ingestion.sql     DOCUMENT_STAGE, DOCUMENT_CONTEXT_ITEMS, ATS_KNOWLEDGE_CORPUS (updated), INGEST_DOCUMENT_FROM_STAGE, INGEST_DOCUMENT_TEXT, LIST_DOCUMENTS, REMOVE_DOCUMENT
v4_tools.sql                  All 35 ATS_TOOL_* stored procedures
v4_agents.sql                 All 6 Cortex Agents (deploy after v4_tools.sql)
```

---

## Known Limitations

| Area | Limitation |
|------|-----------|
| `snow sql -f` | Cannot deploy SQL Scripting SPs with `\|\|` concatenation inside `$$` blocks. Use Python connector deploy script instead. |
| Cost attribution | Cortex credit data has up to 45-minute delay from `CORTEX_FUNCTIONS_USAGE_HISTORY`. Warehouse credits are near-real-time. |
| Cortex Search refresh | `ATS_KNOWLEDGE_SEARCH` refreshes approximately every hour. Newly ingested documents and learnings are not immediately searchable. |
| ATS_PIPELINE_SEMANTICS | Semantic view must be regenerated if the schema of framework tables changes. Run `demo/regenerate_semantic_view.py`. |
| Multi-source bootstrap | `BOOTSTRAP` supports comma-separated `bronze_sources` but all sources must be accessible from the framework database with the executing role. |
