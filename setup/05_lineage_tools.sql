-- =============================================================================
-- 05_lineage_tools.sql
-- LINEAGE AGENT TOOLS — isolated tool SPs for pipeline lineage observability.
--
-- Design principle: each SP does ONE thing, returns JSON VARCHAR.
-- Agents call these tools; Streamlit reads what they write.
-- All tools follow the ATS_TOOL_<VERB>_<NOUN> naming convention.
--
-- Tools:
--   ATS_TOOL_RECORD_SILVER_DDL    — Executor calls after each successful table
--   ATS_TOOL_CHECK_PIPELINE_STALENESS — Compares live Bronze counts vs stored
--   ATS_TOOL_GET_TABLE_IMPACT     — Downstream Silver dependencies for a table
--   ATS_TOOL_GET_SILVER_DDL       — Returns stored DDL + parsed column list
-- =============================================================================

USE DATABASE IDENTIFIER($TARGET_DB);
USE WAREHOUSE IDENTIFIER($WAREHOUSE);

-- =============================================================================
-- LINEAGE TOOLS
-- =============================================================================

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_RECORD_SILVER_DDL(
    bronze_table  VARCHAR,
    silver_ddl    VARCHAR,
    execution_id  VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json, re

def run(session, bronze_table: str, silver_ddl: str, execution_id: str) -> str:
    try:
        # Parse column names from SELECT clause of the DDL
        cols = []
        select_match = re.search(r'SELECT\s+(.*?)\s+FROM\s', silver_ddl, re.IGNORECASE | re.DOTALL)
        if select_match:
            raw = select_match.group(1)
            for part in raw.split(','):
                token = re.split(r'\s+', part.strip())[-1].strip('`"\'')
                if token and token.upper() not in ('*', 'FROM', 'WHERE', 'AS'):
                    cols.append(token)

        session.sql(
            "UPDATE AGENT_FRAMEWORK.TABLE_LINEAGE_MAP "
            "SET silver_ddl = ?, last_execution_id = ?, updated_at = CURRENT_TIMESTAMP() "
            "WHERE UPPER(bronze_table) = UPPER(?)"
        ).bind([silver_ddl, execution_id, bronze_table]).collect()

        return json.dumps({
            "status":        "recorded",
            "bronze_table":  bronze_table,
            "execution_id":  execution_id,
            "columns_parsed": cols,
            "column_count":  len(cols)
        })
    except Exception as e:
        return json.dumps({"error": str(e), "bronze_table": bronze_table})
$$;


CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_CHECK_PIPELINE_STALENESS()
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json

def run(session) -> str:
    try:
        rows = session.sql("""
            SELECT bronze_database, bronze_schema, bronze_table,
                   row_count_bronze AS stored_count,
                   last_refreshed_at
            FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP
            WHERE silver_status = 'COMPLETE'
              AND bronze_table IS NOT NULL
            ORDER BY bronze_table
        """).collect()

        results = []
        for r in rows:
            fqn = f"{r['BRONZE_DATABASE']}.{r['BRONZE_SCHEMA']}.{r['BRONZE_TABLE']}"
            try:
                cnt_row = session.sql(f"SELECT COUNT(*) AS n FROM {fqn}").collect()
                live_count = int(cnt_row[0]['N']) if cnt_row else 0
            except Exception:
                live_count = None

            stored = int(r['STORED_COUNT'] or 0)
            if live_count is None:
                stale = None
                delta = None
            else:
                delta = live_count - stored
                stale = abs(delta) > 0

            results.append({
                "table":          r['BRONZE_TABLE'],
                "fqn":            fqn,
                "stored_count":   stored,
                "live_count":     live_count,
                "delta":          delta,
                "stale":          stale,
                "last_refreshed": str(r['LAST_REFRESHED_AT'])
            })

        stale_count = sum(1 for r in results if r['stale'])
        return json.dumps({
            "total_tables": len(results),
            "stale_tables": stale_count,
            "fresh_tables": len(results) - stale_count,
            "tables":       results
        }, default=str)
    except Exception as e:
        return json.dumps({"error": str(e)})
$$;


CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_GET_TABLE_IMPACT(
    table_name VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    direct_deps   VARIANT;
    indirect_deps VARIANT;
    lineage_row   VARIANT;
BEGIN
    -- Direct downstream: Silver tables that reference this Bronze table
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
        'silver_table',  lm.silver_table,
        'silver_schema', lm.silver_schema,
        'silver_status', lm.silver_status,
        'row_count',     lm.row_count_silver
    )) INTO :lineage_row
    FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP lm
    WHERE UPPER(lm.bronze_table) = UPPER(:table_name);

    -- FK relationships: other tables that have a column pointing INTO this table
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
        'dependent_table',  SPLIT_PART(sr.source_table, '.', -1),
        'fk_column',        sr.source_column,
        'references_column',sr.target_column,
        'relationship_type',sr.relationship_type,
        'confidence',       ROUND(sr.confidence * 100)
    )) INTO :direct_deps
    FROM AGENT_FRAMEWORK.SCHEMA_RELATIONSHIPS sr
    WHERE UPPER(SPLIT_PART(sr.target_table, '.', -1)) = UPPER(:table_name)
    ORDER BY sr.confidence DESC;

    -- Reverse: what does this table depend ON
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
        'parent_table',     SPLIT_PART(sr.target_table, '.', -1),
        'fk_column',        sr.source_column,
        'references_column',sr.target_column,
        'confidence',       ROUND(sr.confidence * 100)
    )) INTO :indirect_deps
    FROM AGENT_FRAMEWORK.SCHEMA_RELATIONSHIPS sr
    WHERE UPPER(SPLIT_PART(sr.source_table, '.', -1)) = UPPER(:table_name)
    ORDER BY sr.confidence DESC;

    RETURN OBJECT_CONSTRUCT(
        'table',             :table_name,
        'silver_output',     :lineage_row,
        'tables_that_reference_this', :direct_deps,
        'tables_this_references',     :indirect_deps
    )::VARCHAR;
EXCEPTION WHEN OTHER THEN
    RETURN OBJECT_CONSTRUCT('table', :table_name, 'error', SQLERRM)::VARCHAR;
END;
$$;


CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_GET_SILVER_DDL(
    bronze_table VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json, re

def run(session, bronze_table: str) -> str:
    try:
        rows = session.sql(f"""
            SELECT bronze_table, silver_table, silver_schema,
                   silver_ddl, row_count_bronze, row_count_silver,
                   last_execution_id, last_refreshed_at
            FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP
            WHERE UPPER(bronze_table) = UPPER('{bronze_table}')
            LIMIT 1
        """).collect()

        if not rows:
            return json.dumps({"error": f"No lineage record found for {bronze_table}"})

        r = rows[0]
        ddl = r['SILVER_DDL'] or ''

        # Parse column names from SELECT clause
        cols = []
        select_match = re.search(r'SELECT\s+(.*?)\s+FROM\s', ddl, re.IGNORECASE | re.DOTALL)
        if select_match:
            for part in select_match.group(1).split(','):
                token = re.split(r'\s+', part.strip())[-1].strip('`"\'')
                if token and token.upper() not in ('*', 'FROM', 'WHERE', 'AS'):
                    cols.append(token)

        return json.dumps({
            "bronze_table":    r['BRONZE_TABLE'],
            "silver_table":    r['SILVER_TABLE'],
            "silver_schema":   r['SILVER_SCHEMA'],
            "silver_ddl":      ddl,
            "columns":         cols,
            "row_count_bronze":r['ROW_COUNT_BRONZE'],
            "row_count_silver":r['ROW_COUNT_SILVER'],
            "execution_id":    r['LAST_EXECUTION_ID'],
            "last_refreshed":  str(r['LAST_REFRESHED_AT'])
        }, default=str)
    except Exception as e:
        return json.dumps({"error": str(e), "bronze_table": bronze_table})
$$;
