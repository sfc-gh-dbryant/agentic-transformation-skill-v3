-- =============================================================================
-- 00_bootstrap.sql
-- Creates AGENT_FRAMEWORK schema, MODEL_CONFIG, VALIDATE_MODEL, and BOOTSTRAP SPs.
-- =============================================================================
-- Usage:
--   SET TARGET_DB = 'YOUR_DATABASE';   -- required
--   Then run this file, or use deploy.sh to inject automatically.
-- =============================================================================

USE DATABASE IDENTIFIER($TARGET_DB);

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS AGENT_FRAMEWORK;

CREATE STAGE IF NOT EXISTS AGENT_FRAMEWORK.AGENT_STAGE
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    DIRECTORY  = (ENABLE = TRUE)
    COMMENT    = 'General-purpose stage for AGENT_FRAMEWORK exports (DCM projects, etc.)';

-- ---------------------------------------------------------------------------
-- MODEL_CONFIG
-- Single-row table. No stored procedure anywhere in this codebase should
-- hardcode a Cortex model name. Always read from here at runtime.
-- See docs/decisions/001-model-configuration.md for rationale.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS AGENT_FRAMEWORK.MODEL_CONFIG (
    config_key      VARCHAR         NOT NULL DEFAULT 'default',
    primary_model   VARCHAR         NOT NULL DEFAULT 'claude-3-7-sonnet',
    fallback_model  VARCHAR                  DEFAULT 'mistral-large2',
    validated       BOOLEAN                  DEFAULT FALSE,
    last_validated  TIMESTAMP_NTZ,
    updated_at      TIMESTAMP_NTZ            DEFAULT CURRENT_TIMESTAMP(),
    updated_by      VARCHAR                  DEFAULT CURRENT_USER(),
    CONSTRAINT pk_model_config PRIMARY KEY (config_key)
);

INSERT INTO AGENT_FRAMEWORK.MODEL_CONFIG (config_key, primary_model, fallback_model)
SELECT 'default', 'claude-3-7-sonnet', 'mistral-large2'
WHERE NOT EXISTS (
    SELECT 1 FROM AGENT_FRAMEWORK.MODEL_CONFIG WHERE config_key = 'default'
);

-- ---------------------------------------------------------------------------
-- VALIDATE_MODEL
-- Tests a Cortex model with a lightweight prompt and updates MODEL_CONFIG.
-- Called by BOOTSTRAP and exposed in Streamlit Tab 1 "Re-validate Model".
-- If test_model is NULL, tries the priority list and picks the first that works.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.VALIDATE_MODEL(test_model VARCHAR DEFAULT NULL)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    model_priority ARRAY DEFAULT ARRAY_CONSTRUCT(
        'llama3.3-70b',
        'claude-3-7-sonnet',
        'claude-3-5-sonnet-v2',
        'mistral-large2'
    );
    model_to_test VARCHAR;
    test_response VARCHAR;
    result VARIANT;
    i INTEGER;
BEGIN
    IF (test_model IS NOT NULL) THEN
        model_to_test := test_model;
        BEGIN
            SELECT SNOWFLAKE.CORTEX.COMPLETE(
                :model_to_test,
                'Reply with the word OK only.'
            ) INTO :test_response;
            IF (CONTAINS(UPPER(test_response), 'OK')) THEN
                UPDATE AGENT_FRAMEWORK.MODEL_CONFIG
                SET primary_model  = :model_to_test,
                    validated      = TRUE,
                    last_validated = CURRENT_TIMESTAMP(),
                    updated_at     = CURRENT_TIMESTAMP(),
                    updated_by     = CURRENT_USER()
                WHERE config_key = 'default';

                RETURN OBJECT_CONSTRUCT(
                    'status',  'SUCCESS',
                    'model',   model_to_test,
                    'message', 'Model validated and set as primary'
                );
            END IF;
        EXCEPTION WHEN OTHER THEN
            RETURN OBJECT_CONSTRUCT(
                'status',  'FAILED',
                'model',   test_model,
                'error',   SQLERRM
            );
        END;
    END IF;

    FOR i IN 0 TO ARRAY_SIZE(model_priority) - 1 DO
        model_to_test := model_priority[i]::VARCHAR;
        BEGIN
            SELECT SNOWFLAKE.CORTEX.COMPLETE(
                :model_to_test,
                'Reply with the word OK only.'
            ) INTO :test_response;

            UPDATE AGENT_FRAMEWORK.MODEL_CONFIG
            SET primary_model  = :model_to_test,
                validated      = TRUE,
                last_validated = CURRENT_TIMESTAMP(),
                updated_at     = CURRENT_TIMESTAMP(),
                updated_by     = CURRENT_USER()
            WHERE config_key = 'default';

            RETURN OBJECT_CONSTRUCT(
                'status',  'SUCCESS',
                'model',   model_to_test,
                'message', 'Auto-selected from priority list'
            );
        EXCEPTION WHEN OTHER THEN
            CONTINUE;
        END;
    END FOR;

    RETURN OBJECT_CONSTRUCT(
        'status',  'FAILED',
        'model',   NULL,
        'message', 'No available Cortex model found in priority list'
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- RESET_FRAMEWORK  [v3 — was referenced by Streamlit but never defined in v2]
-- Clears all runtime workflow data. Preserves config tables.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.RESET_FRAMEWORK(confirm VARCHAR DEFAULT NULL)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    IF (UPPER(COALESCE(:confirm, '')) != 'YES') THEN
        RETURN 'ERROR: Pass confirm=>''YES'' to reset. This truncates all runtime tables.';
    END IF;

    TRUNCATE TABLE IF EXISTS AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS;
    TRUNCATE TABLE IF EXISTS AGENT_FRAMEWORK.WORKFLOW_LOG;
    TRUNCATE TABLE IF EXISTS AGENT_FRAMEWORK.PLANNER_DECISIONS;
    TRUNCATE TABLE IF EXISTS AGENT_FRAMEWORK.TABLE_LINEAGE_MAP;
    TRUNCATE TABLE IF EXISTS AGENT_FRAMEWORK.SCHEMA_RELATIONSHIPS;

    RETURN OBJECT_CONSTRUCT(
        'status',    'RESET',
        'cleared',   ARRAY_CONSTRUCT(
            'WORKFLOW_EXECUTIONS', 'WORKFLOW_LOG',
            'PLANNER_DECISIONS',   'TABLE_LINEAGE_MAP',
            'SCHEMA_RELATIONSHIPS'
        ),
        'preserved', ARRAY_CONSTRUCT(
            'MODEL_CONFIG',           'PIPELINE_CONTEXT',
            'SCHEMA_CONTRACTS',       'TRANSFORMATION_DIRECTIVES',
            'PARTNER_BANNER_CONFIG'
        )
    )::VARCHAR;
END;
$$;

-- ---------------------------------------------------------------------------
-- CLEAR_WORKFLOW_HISTORY
-- Removes run history and planner decisions without touching lineage map,
-- contracts, or directives. Safe to call between demo runs.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.CLEAR_WORKFLOW_HISTORY()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    DELETE FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS;
    DELETE FROM AGENT_FRAMEWORK.PLANNER_DECISIONS;
    DELETE FROM AGENT_FRAMEWORK.SCHEMA_RELATIONSHIPS;
    DELETE FROM AGENT_FRAMEWORK.WORKFLOW_LOG;
    RETURN OBJECT_CONSTRUCT(
        'status',  'CLEARED',
        'cleared', ARRAY_CONSTRUCT(
            'WORKFLOW_EXECUTIONS', 'PLANNER_DECISIONS',
            'SCHEMA_RELATIONSHIPS', 'WORKFLOW_LOG'
        )
    )::VARCHAR;
END;
$$;

-- ---------------------------------------------------------------------------
-- BOOTSTRAP
-- One-call initialization: validates model, discovers Bronze tables,
-- seeds defaults. Call after all 00-05 scripts have run.
--
-- bronze_sources accepts:
--   'BRONZE'                        plain schema name — current database
--   'MY_DATA_DB.BRONZE'             fully-qualified — cross-database
--   'DB1.BRONZE,DB2.RAW,DB3.STAGE'  comma-separated — multiple sources
--
-- This is the real-world pattern: the framework DB (ATS_V3) is always
-- separate from customer Bronze data (e.g. ATS_V3_TEST.BRONZE).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.BOOTSTRAP(bronze_sources VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json

def discover_source(session, source: str, current_db: str) -> list:
    """
    Discover tables from a single source spec.
    source can be 'SCHEMA', 'DATABASE.SCHEMA', or 'DATABASE.SCHEMA' (case-insensitive).
    Returns list of (database, schema, table_name) tuples.
    """
    source = source.strip()
    if '.' in source:
        parts = source.split('.', 1)
        db     = parts[0].upper()
        schema = parts[1].upper()
    else:
        db     = current_db.upper()
        schema = source.upper()

    sql = (
        f"SELECT TABLE_NAME, TABLE_SCHEMA, TABLE_CATALOG "
        f"FROM {db}.INFORMATION_SCHEMA.TABLES "
        f"WHERE UPPER(TABLE_SCHEMA) = '{schema}' "
        f"AND TABLE_TYPE = 'BASE TABLE'"
    )
    try:
        rows = session.sql(sql).collect()
        return [(db, schema, r['TABLE_NAME']) for r in rows]
    except Exception as e:
        return []   # source unreachable or schema doesn't exist — skip silently

def run(session, bronze_sources: str) -> str:
    current_db = session.sql("SELECT CURRENT_DATABASE()").collect()[0][0]

    # Step 0: ensure safe output schema exists
    for ddl in [
        "CREATE SCHEMA IF NOT EXISTS AGENT_FRAMEWORK_OUTPUT",
        "CREATE SCHEMA IF NOT EXISTS SILVER",
        "CREATE SCHEMA IF NOT EXISTS GOLD",
    ]:
        session.sql(ddl).collect()

    # Step 1: validate and auto-select Cortex model
    model_result = {}
    try:
        row = session.sql(
            "CALL AGENT_FRAMEWORK.VALIDATE_MODEL(NULL)"
        ).collect()[0][0]
        model_result = json.loads(row) if isinstance(row, str) else row
    except Exception as e:
        model_result = {"status": "FAILED", "error": str(e)}

    # Step 2: discover Bronze tables from all sources
    sources = [s.strip() for s in bronze_sources.split(',') if s.strip()]
    discovered = []
    skipped_sources = []

    for source in sources:
        tables = discover_source(session, source, current_db)
        if tables:
            discovered.extend(tables)
        else:
            skipped_sources.append(source)

    # Step 3: insert newly discovered tables into TABLE_LINEAGE_MAP
    inserted = 0
    for (db, schema, tbl) in discovered:
        try:
            session.sql(
                "INSERT INTO AGENT_FRAMEWORK.TABLE_LINEAGE_MAP "
                "(bronze_table, bronze_schema, bronze_database, discovery_method) "
                "SELECT ?, ?, ?, 'BOOTSTRAP' "
                "WHERE NOT EXISTS ("
                "    SELECT 1 FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP "
                "    WHERE UPPER(bronze_table)    = UPPER(?) "
                "      AND UPPER(bronze_schema)   = UPPER(?) "
                "      AND UPPER(bronze_database) = UPPER(?)"
                ")",
                params=[tbl, schema, db, tbl, schema, db]
            ).collect()
            inserted += 1
        except Exception:
            pass

    # Step 3b: brownfield detection — scan existing tables in output_schema
    # Register any Silver tables that already exist but are not tracked by ATS
    brownfield_count = 0
    try:
        ctx_rows = session.sql(
            "SELECT COALESCE(NULLIF(output_schema,''),'AGENT_FRAMEWORK_OUTPUT'), "
            "       COALESCE(brownfield_mode, FALSE) "
            "FROM AGENT_FRAMEWORK.PIPELINE_CONTEXT WHERE context_id = 1"
        ).collect()
        output_schema   = ctx_rows[0][0] if ctx_rows else 'AGENT_FRAMEWORK_OUTPUT'
        brownfield_mode = ctx_rows[0][1] if ctx_rows else False

        if brownfield_mode:
            schema_parts = output_schema.split('.')
            bf_db     = schema_parts[0] if len(schema_parts) > 1 else current_db
            bf_schema = schema_parts[-1]
            existing = session.sql(
                f"SELECT TABLE_NAME FROM {bf_db}.INFORMATION_SCHEMA.TABLES "
                f"WHERE UPPER(TABLE_SCHEMA) = UPPER('{bf_schema}') "
                f"AND TABLE_TYPE = 'BASE TABLE'"
            ).collect()
            for row in existing:
                tbl_name = row['TABLE_NAME']
                # Only register if there is a matching Bronze table but no Silver tracked yet
                matches = session.sql(
                    "SELECT lineage_id FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP "
                    "WHERE UPPER(bronze_table) = UPPER(?) AND silver_status = 'PENDING'",
                    params=[tbl_name]
                ).collect()
                if matches:
                    session.sql(
                        "UPDATE AGENT_FRAMEWORK.TABLE_LINEAGE_MAP "
                        "SET silver_table  = ?, silver_schema = ?, "
                        "    silver_status = 'EXISTING', updated_at = CURRENT_TIMESTAMP() "
                        "WHERE UPPER(bronze_table) = UPPER(?) AND silver_status = 'PENDING'",
                        params=[tbl_name, output_schema, tbl_name]
                    ).collect()
                    brownfield_count += 1
    except Exception:
        pass  # brownfield detection is best-effort; never block Bootstrap

    table_count = session.sql(
        "SELECT COUNT(*) AS cnt FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP"
    ).collect()[0]['CNT']

    # Step 4: seed contracts if empty
    contract_count = session.sql(
        "SELECT COUNT(*) AS cnt FROM AGENT_FRAMEWORK.SCHEMA_CONTRACTS"
    ).collect()[0]['CNT']
    if contract_count == 0:
        session.sql("CALL AGENT_FRAMEWORK.SEED_DEFAULT_CONTRACTS()").collect()
        contract_count = session.sql(
            "SELECT COUNT(*) AS cnt FROM AGENT_FRAMEWORK.SCHEMA_CONTRACTS"
        ).collect()[0]['CNT']

    # Step 5: seed directives if empty
    directive_count = session.sql(
        "SELECT COUNT(*) AS cnt FROM AGENT_FRAMEWORK.TRANSFORMATION_DIRECTIVES"
    ).collect()[0]['CNT']
    if directive_count == 0:
        session.sql("CALL AGENT_FRAMEWORK.SEED_DEFAULT_DIRECTIVES()").collect()
        directive_count = session.sql(
            "SELECT COUNT(*) AS cnt FROM AGENT_FRAMEWORK.TRANSFORMATION_DIRECTIVES"
        ).collect()[0]['CNT']

    return json.dumps({
        "status":                    "SUCCESS",
        "framework_db":              current_db,
        "sources_requested":         sources,
        "sources_skipped":           skipped_sources,
        "tables_discovered":         len(discovered),
        "tables_registered":         int(table_count),
        "newly_inserted":            inserted,
        "brownfield_existing_found": brownfield_count,
        "model_validation":          model_result,
        "contracts_seeded":          int(contract_count),
        "directives_seeded":         int(directive_count)
    })
$$;
