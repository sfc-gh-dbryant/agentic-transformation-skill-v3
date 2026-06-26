-- =============================================================================
-- 01_transformation_registry.sql
-- Transformation Registry: lineage, execution history, planner decisions,
-- and workflow learnings. This replaces the Knowledge Graph (KG) from ADF.
-- The semantic layer nodes/edges and VQR tracking are intentionally excluded.
-- =============================================================================

USE DATABASE IDENTIFIER($TARGET_DB);

-- ---------------------------------------------------------------------------
-- TABLE_LINEAGE_MAP
-- Single source of truth for Bronze → Silver → Gold coverage.
-- Populated at bootstrap (Bronze entries) and updated by the workflow engine.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS AGENT_FRAMEWORK.TABLE_LINEAGE_MAP (
    lineage_id          VARCHAR         DEFAULT UUID_STRING(),
    bronze_table        VARCHAR         NOT NULL,
    bronze_schema       VARCHAR         NOT NULL,
    bronze_database     VARCHAR         NOT NULL,
    silver_table        VARCHAR,
    silver_schema       VARCHAR,
    gold_table          VARCHAR,
    gold_schema         VARCHAR,
    last_execution_id   VARCHAR,
    silver_status       VARCHAR         DEFAULT 'PENDING',
    gold_status         VARCHAR         DEFAULT 'PENDING',
    row_count_bronze    INTEGER,
    row_count_silver    INTEGER,
    row_count_gold      INTEGER,
    discovery_method    VARCHAR         DEFAULT 'MANUAL',
    last_refreshed_at   TIMESTAMP_NTZ,
    created_at          TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    updated_at          TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_lineage PRIMARY KEY (lineage_id),
    CONSTRAINT uq_bronze UNIQUE (bronze_table, bronze_schema, bronze_database)
);

-- ---------------------------------------------------------------------------
-- WORKFLOW_EXECUTIONS
-- One row per agentic workflow run. All four phases write back here.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS (
    execution_id            VARCHAR         DEFAULT UUID_STRING(),
    workflow_name           VARCHAR         NOT NULL,
    trigger_source          VARCHAR,
    trigger_type            VARCHAR,
    status                  VARCHAR         DEFAULT 'PENDING',
    current_phase           VARCHAR,
    tables_requested        ARRAY,
    planner_output          VARIANT,
    executor_output         VARIANT,
    validator_output        VARIANT,
    reflector_output        VARIANT,
    started_at              TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    planning_completed_at   TIMESTAMP_NTZ,
    execution_completed_at  TIMESTAMP_NTZ,
    validation_completed_at TIMESTAMP_NTZ,
    reflection_completed_at TIMESTAMP_NTZ,
    completed_at            TIMESTAMP_NTZ,
    retry_count             INTEGER         DEFAULT 0,
    max_retries             INTEGER         DEFAULT 3,
    last_error              TEXT,
    CONSTRAINT pk_executions PRIMARY KEY (execution_id)
);

-- ---------------------------------------------------------------------------
-- PLANNER_DECISIONS
-- One row per table per execution. Stores the LLM's planning output.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS AGENT_FRAMEWORK.PLANNER_DECISIONS (
    decision_id                 VARCHAR     DEFAULT UUID_STRING(),
    execution_id                VARCHAR     NOT NULL,
    source_table                VARCHAR     NOT NULL,
    target_schema               VARCHAR,
    transformation_strategy     VARCHAR,
    detected_patterns           VARIANT,
    recommended_actions         ARRAY,
    priority                    INTEGER,
    llm_reasoning               TEXT,
    pk_columns                  VARCHAR,
    confidence_score            FLOAT,
    model_used                  VARCHAR,
    schema_fingerprint          VARCHAR,
    created_at                  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_decisions PRIMARY KEY (decision_id)
);

-- ---------------------------------------------------------------------------
-- WORKFLOW_LEARNINGS
-- The system's memory. Written by the REFLECTOR phase. Persists across runs.
-- High-confidence learnings are injected into future PLANNER prompts.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS AGENT_FRAMEWORK.WORKFLOW_LEARNINGS (
    learning_id         VARCHAR         DEFAULT UUID_STRING(),
    execution_id        VARCHAR,
    learning_type       VARCHAR,
    source_context      VARCHAR,
    pattern_signature   VARCHAR,
    observation         TEXT,
    recommendation      TEXT,
    times_observed      INTEGER         DEFAULT 1,
    last_observed_at    TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    confidence_score    FLOAT,
    is_active           BOOLEAN         DEFAULT TRUE,
    CONSTRAINT pk_learnings PRIMARY KEY (learning_id)
);

-- ---------------------------------------------------------------------------
-- WORKFLOW_LOG
-- Operational log for debugging. Not surfaced in Streamlit by default.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS AGENT_FRAMEWORK.WORKFLOW_LOG (
    log_id          VARCHAR         DEFAULT UUID_STRING(),
    execution_id    VARCHAR,
    phase           VARCHAR,
    status          VARCHAR,
    message         TEXT,
    created_at      TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
);

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW AGENT_FRAMEWORK.COVERAGE_SUMMARY AS
SELECT
    bronze_database,
    bronze_schema,
    COUNT(*)                                                            AS total_bronze_tables,
    COUNT(silver_table)                                                 AS silver_covered,
    COUNT(gold_table)                                                   AS gold_covered,
    ROUND(COUNT(silver_table) * 100.0 / NULLIF(COUNT(*), 0), 1)        AS silver_pct,
    ROUND(COUNT(gold_table)   * 100.0 / NULLIF(COUNT(*), 0), 1)        AS gold_pct
FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP
GROUP BY 1, 2;

CREATE OR REPLACE VIEW AGENT_FRAMEWORK.SILVER_GAPS AS
SELECT
    bronze_table,
    bronze_schema,
    bronze_database,
    silver_status,
    last_refreshed_at
FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP
WHERE silver_table IS NULL
ORDER BY bronze_table;

CREATE OR REPLACE VIEW AGENT_FRAMEWORK.GOLD_GAPS AS
SELECT
    bronze_table,
    silver_table,
    bronze_schema,
    silver_schema,
    gold_status,
    last_refreshed_at
FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP
WHERE silver_table IS NOT NULL
  AND gold_table IS NULL
ORDER BY silver_table;
