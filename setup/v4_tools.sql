-- =============================================================================
-- v4_tools.sql
-- ATS v4 Tool Stored Procedures — one SP per agent tool.
-- All tools follow the same contract:
--   - Input:  named parameters matching the Cortex Agent JSON schema
--   - Output: VARCHAR (JSON) — agent reads this as reasoning context
-- Naming convention: ATS_TOOL_<VERB>_<NOUN>
-- =============================================================================

USE DATABASE IDENTIFIER($TARGET_DB);
USE WAREHOUSE IDENTIFIER($WAREHOUSE);

-- =============================================================================
-- SCHEMA ANALYST AGENT TOOLS
-- =============================================================================

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_DISCOVER_SCHEMA(fqn VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    result VARIANT;
BEGIN
    LET db      VARCHAR := SPLIT_PART(:fqn, '.', 1);
    LET schema  VARCHAR := SPLIT_PART(:fqn, '.', 2);
    LET tbl     VARCHAR := SPLIT_PART(:fqn, '.', 3);
    LET col_sql VARCHAR := 'SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
        ''column_name'', COLUMN_NAME,
        ''data_type'',   DATA_TYPE,
        ''ordinal'',     ORDINAL_POSITION,
        ''nullable'',    IS_NULLABLE
    )) AS cols
    FROM (SELECT COLUMN_NAME, DATA_TYPE, ORDINAL_POSITION, IS_NULLABLE
          FROM ' || :db || '.INFORMATION_SCHEMA.COLUMNS
          WHERE UPPER(TABLE_SCHEMA) = UPPER(''' || :schema || ''')
            AND UPPER(TABLE_NAME)   = UPPER(''' || :tbl    || ''')
          ORDER BY ORDINAL_POSITION)
    sub';
    LET rs  RESULTSET := (EXECUTE IMMEDIATE :col_sql);
    LET cur CURSOR FOR rs;
    OPEN cur;
    FETCH cur INTO result;
    CLOSE cur;
    RETURN OBJECT_CONSTRUCT('fqn', :fqn, 'columns', result)::VARCHAR;
EXCEPTION WHEN OTHER THEN
    RETURN OBJECT_CONSTRUCT('fqn', :fqn, 'error', SQLERRM)::VARCHAR;
END;
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_SAMPLE_DATA(fqn VARCHAR, n INTEGER)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json

def run(session, fqn: str, n: int) -> str:
    try:
        rows = session.sql(f"SELECT * FROM {fqn} LIMIT {min(n, 20)}").collect()
        return json.dumps({"fqn": fqn, "rows": [r.as_dict() for r in rows]}, default=str)
    except Exception as e:
        return json.dumps({"fqn": fqn, "error": str(e)})
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_SEARCH_RELATIONSHIPS(query VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    LET result VARCHAR;
    CALL AGENT_FRAMEWORK.SEARCH_ATS_KNOWLEDGE(:query, 5) INTO :result;
    RETURN OBJECT_CONSTRUCT('query', :query, 'results', :result)::VARCHAR;
END;
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_LIST_TABLES(db VARCHAR, schema_name VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json

def run(session, db: str, schema_name: str) -> str:
    try:
        rows = session.sql(
            f"SELECT TABLE_NAME, TABLE_TYPE, ROW_COUNT "
            f"FROM {db}.INFORMATION_SCHEMA.TABLES "
            f"WHERE UPPER(TABLE_SCHEMA) = UPPER('{schema_name}') "
            f"AND TABLE_TYPE IN ('BASE TABLE', 'VIEW') ORDER BY TABLE_NAME"
        ).collect()
        return json.dumps({"db": db, "schema": schema_name,
                           "tables": [{"name": r["TABLE_NAME"], "type": r["TABLE_TYPE"],
                                       "row_count": r["ROW_COUNT"]} for r in rows]})
    except Exception as e:
        return json.dumps({"db": db, "schema": schema_name, "error": str(e)})
$$;

-- =============================================================================
-- PLANNER AGENT TOOLS
-- =============================================================================

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_GET_PIPELINE_CONTEXT()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE ctx VARIANT;
BEGIN
    SELECT OBJECT_CONSTRUCT(
        'business_desc',   business_desc,
        'data_domain',     data_domain,
        'gold_goals',      gold_goals,
        'constraints',     constraints,
        'pipeline_type',   pipeline_type,
        'output_schema',   output_schema,
        'dry_run',         dry_run,
        'gold_output_mode', gold_output_mode,
        'brownfield_mode', brownfield_mode
    ) INTO :ctx
    FROM AGENT_FRAMEWORK.PIPELINE_CONTEXT WHERE context_id = 1;
    RETURN :ctx::VARCHAR;
END;
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_GET_CONTRACTS(layer VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json

def run(session, layer: str) -> str:
    rows = session.sql(
        "SELECT rule_name, rule_value, rule_category FROM AGENT_FRAMEWORK.SCHEMA_CONTRACTS "
        "WHERE is_active = TRUE AND (UPPER(applies_to_layer) = UPPER(?) OR applies_to_layer IS NULL) "
        "ORDER BY rule_category ASC",
        params=[layer]
    ).collect()
    return json.dumps({"layer": layer, "contracts": [
        {"rule": r["RULE_NAME"], "text": r["RULE_VALUE"], "category": r["RULE_CATEGORY"]}
        for r in rows
    ]})
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_GET_DIRECTIVES(table_pattern VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json

def run(session, table_pattern: str) -> str:
    rows = session.sql(
        "SELECT use_case, source_table_pattern, instructions, priority "
        "FROM AGENT_FRAMEWORK.ACTIVE_DIRECTIVES "
        "WHERE UPPER(?) LIKE UPPER(source_table_pattern) ORDER BY priority ASC",
        params=[table_pattern]
    ).collect()
    return json.dumps({"table_pattern": table_pattern, "directives": [
        {"use_case": r["USE_CASE"], "instructions": r["INSTRUCTIONS"],
         "priority": r["PRIORITY"]}
        for r in rows
    ]})
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_GET_SCHEMA_RELATIONSHIPS(execution_id VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json

def run(session, execution_id: str) -> str:
    rows = session.sql(
        "SELECT source_table, source_column, target_table, target_column, "
        "relationship_type, confidence "
        "FROM AGENT_FRAMEWORK.SCHEMA_RELATIONSHIPS "
        "WHERE execution_id = ? AND confidence >= 0.65 ORDER BY confidence DESC",
        params=[execution_id]
    ).collect()
    return json.dumps({"execution_id": execution_id, "relationships": [
        {"source": f"{r['SOURCE_TABLE']}.{r['SOURCE_COLUMN']}",
         "target": f"{r['TARGET_TABLE']}.{r['TARGET_COLUMN']}",
         "type": r["RELATIONSHIP_TYPE"], "confidence": r["CONFIDENCE"]}
        for r in rows
    ]})
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_SEARCH_PRIOR_DECISIONS(query VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    LET result VARCHAR;
    CALL AGENT_FRAMEWORK.SEARCH_ATS_KNOWLEDGE(:query, 5) INTO :result;
    RETURN OBJECT_CONSTRUCT('query', :query, 'prior_decisions', :result)::VARCHAR;
END;
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_GET_GOLD_SCHEMAS()
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json

def run(session) -> str:
    rows = session.sql(
        "SELECT bronze_table, silver_table, silver_schema, gold_table, gold_schema, silver_status "
        "FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP ORDER BY bronze_table"
    ).collect()
    return json.dumps({"gold_schemas": [
        {"bronze": r["BRONZE_TABLE"], "silver": r["SILVER_TABLE"],
         "gold": r["GOLD_TABLE"], "status": r["SILVER_STATUS"]}
        for r in rows
    ]})
$$;

-- =============================================================================
-- EXECUTOR AGENT TOOLS
-- =============================================================================

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_GET_COLUMNS(fqn VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json

def run(session, fqn: str) -> str:
    parts = fqn.split('.')
    db, schema, table = parts[0], parts[1], parts[2]
    try:
        rows = session.sql(
            f"SELECT COLUMN_NAME, DATA_TYPE, ORDINAL_POSITION, IS_NULLABLE "
            f"FROM {db}.INFORMATION_SCHEMA.COLUMNS "
            f"WHERE UPPER(TABLE_SCHEMA) = UPPER('{schema}') "
            f"AND UPPER(TABLE_NAME) = UPPER('{table}') "
            f"ORDER BY ORDINAL_POSITION"
        ).collect()
        return json.dumps({
            "fqn": fqn,
            "column_count": len(rows),
            "columns": [{"name": r["COLUMN_NAME"], "type": r["DATA_TYPE"],
                         "nullable": r["IS_NULLABLE"]} for r in rows],
            "column_list": ", ".join(r["COLUMN_NAME"] for r in rows)
        })
    except Exception as e:
        return json.dumps({"fqn": fqn, "error": str(e)})
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_EXECUTE_DDL(
    execution_id VARCHAR,
    ddl          VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json, re

def run(session, execution_id: str, ddl: str) -> str:
    ctx = session.sql(
        "SELECT COALESCE(dry_run, TRUE) AS dry_run, "
        "COALESCE(NULLIF(output_schema,''),'AGENT_FRAMEWORK_OUTPUT') AS output_schema "
        "FROM AGENT_FRAMEWORK.PIPELINE_CONTEXT WHERE context_id = 1"
    ).collect()
    dry_run     = ctx[0]["DRY_RUN"]     if ctx else True
    output_schema = ctx[0]["OUTPUT_SCHEMA"] if ctx else "AGENT_FRAMEWORK_OUTPUT"

    # Sanitise: strip markdown fences
    clean = re.sub(r'^```(sql)?\s*', '', ddl.strip(), flags=re.IGNORECASE | re.MULTILINE)
    clean = re.sub(r'\s*```\s*$', '', clean, flags=re.MULTILINE).strip()
    clean = clean.rstrip(';')

    target_table = re.search(r'TABLE\s+([\w\.]+)', clean, re.IGNORECASE)
    tbl = target_table.group(1).split('.')[-1] if target_table else "UNKNOWN"

    if dry_run:
        session.sql(
            "INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message) "
            "VALUES (?, 'EXECUTOR_V4', 'DRY_RUN', ?)",
            params=[execution_id, f"[DRY RUN] {tbl} — DDL logged, not executed.\n{clean[:2000]}"]
        ).collect()
        return json.dumps({"status": "DRY_RUN", "table": tbl, "ddl_preview": clean[:500]})
    try:
        session.sql(clean).collect()
        session.sql(
            "UPDATE AGENT_FRAMEWORK.TABLE_LINEAGE_MAP "
            "SET silver_table = ?, silver_schema = ?, silver_status = 'COMPLETE', "
            "    last_execution_id = ?, last_refreshed_at = CURRENT_TIMESTAMP(), "
            "    updated_at = CURRENT_TIMESTAMP() "
            "WHERE bronze_table = ?",
            params=[tbl, output_schema, execution_id, tbl]
        ).collect()
        session.sql(
            "INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message) "
            "VALUES (?, 'EXECUTOR_V4', 'OK', ?)",
            params=[execution_id, f"{tbl} → {output_schema}.{tbl} built successfully"]
        ).collect()
        return json.dumps({"status": "SUCCESS", "table": tbl, "output": f"{output_schema}.{tbl}"})
    except Exception as e:
        session.sql(
            "INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message) "
            "VALUES (?, 'EXECUTOR_V4', 'FAILED', ?)",
            params=[execution_id, f"{tbl} failed: {str(e)[:400]}"]
        ).collect()
        return json.dumps({"status": "FAILED", "table": tbl, "error": str(e)[:400]})
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_VALIDATE_COLUMN(
    table_fqn   VARCHAR,
    column_name VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    col_count INTEGER;
BEGIN
    LET db     VARCHAR := SPLIT_PART(:table_fqn, '.', 1);
    LET schema VARCHAR := SPLIT_PART(:table_fqn, '.', 2);
    LET tbl    VARCHAR := SPLIT_PART(:table_fqn, '.', 3);
    LET chk_sql VARCHAR := 'SELECT COUNT(*) FROM ' || :db ||
        '.INFORMATION_SCHEMA.COLUMNS WHERE UPPER(TABLE_SCHEMA) = UPPER(''' || :schema ||
        ''') AND UPPER(TABLE_NAME) = UPPER(''' || :tbl || ''') AND UPPER(COLUMN_NAME) = UPPER(''' ||
        :column_name || ''')';
    LET rs  RESULTSET := (EXECUTE IMMEDIATE :chk_sql);
    LET cur CURSOR FOR rs;
    OPEN cur;
    FETCH cur INTO col_count;
    CLOSE cur;
    RETURN OBJECT_CONSTRUCT(
        'table',   :table_fqn,
        'column',  :column_name,
        'exists',  (:col_count > 0)
    )::VARCHAR;
END;
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_CHECK_TABLE_EXISTS(fqn VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json

def run(session, fqn: str) -> str:
    try:
        rows = session.sql(f"SELECT COUNT(*) AS cnt FROM {fqn} LIMIT 1").collect()
        count = rows[0]["CNT"] if rows else 0
        return json.dumps({"fqn": fqn, "exists": True, "row_count": count,
                           "safe_to_write": count == 0})
    except Exception:
        return json.dumps({"fqn": fqn, "exists": False, "row_count": 0, "safe_to_write": True})
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_GET_SAMPLE_ROWS(fqn VARCHAR, n INTEGER)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json

def run(session, fqn: str, n: int) -> str:
    try:
        rows = session.sql(f"SELECT * FROM {fqn} LIMIT {min(n, 10)}").collect()
        return json.dumps({"fqn": fqn, "sample_rows": [
            dict(r.as_dict()) for r in rows], "count": len(rows)}, default=str)
    except Exception as e:
        return json.dumps({"fqn": fqn, "error": str(e)})
$$;

-- =============================================================================
-- VALIDATOR AGENT TOOLS
-- =============================================================================

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_COUNT_ROWS(fqn VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE cnt INTEGER;
BEGIN
    LET sql VARCHAR := 'SELECT COUNT(*) FROM ' || :fqn;
    LET rs  RESULTSET := (EXECUTE IMMEDIATE :sql);
    LET cur CURSOR FOR rs;
    OPEN cur;
    FETCH cur INTO cnt;
    CLOSE cur;
    RETURN OBJECT_CONSTRUCT('fqn', :fqn, 'row_count', :cnt)::VARCHAR;
EXCEPTION WHEN OTHER THEN
    RETURN OBJECT_CONSTRUCT('fqn', :fqn, 'error', SQLERRM)::VARCHAR;
END;
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_CHECK_PK_UNIQUENESS(
    fqn     VARCHAR,
    pk_cols VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    total_rows   INTEGER;
    distinct_pks INTEGER;
    dupes        INTEGER;
BEGIN
    LET total_sql   VARCHAR := 'SELECT COUNT(*) FROM ' || :fqn;
    LET distinct_sql VARCHAR := 'SELECT COUNT(*) FROM (SELECT DISTINCT ' || :pk_cols || ' FROM ' || :fqn || ')';
    LET rs1  RESULTSET := (EXECUTE IMMEDIATE :total_sql);
    LET cur1 CURSOR FOR rs1;
    OPEN cur1; FETCH cur1 INTO total_rows; CLOSE cur1;
    LET rs2  RESULTSET := (EXECUTE IMMEDIATE :distinct_sql);
    LET cur2 CURSOR FOR rs2;
    OPEN cur2; FETCH cur2 INTO distinct_pks; CLOSE cur2;
    dupes := total_rows - distinct_pks;
    RETURN OBJECT_CONSTRUCT(
        'fqn',         :fqn,
        'pk_cols',     :pk_cols,
        'total_rows',  :total_rows,
        'distinct_pks', :distinct_pks,
        'duplicate_count', :dupes,
        'is_unique',   (:dupes = 0)
    )::VARCHAR;
EXCEPTION WHEN OTHER THEN
    RETURN OBJECT_CONSTRUCT('fqn', :fqn, 'pk_cols', :pk_cols, 'error', SQLERRM)::VARCHAR;
END;
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_COMPARE_COUNTS(
    source_fqn VARCHAR,
    target_fqn VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    source_count INTEGER;
    target_count INTEGER;
    variance_pct FLOAT;
BEGIN
    LET src_sql VARCHAR := 'SELECT COUNT(*) FROM ' || :source_fqn;
    LET tgt_sql VARCHAR := 'SELECT COUNT(*) FROM ' || :target_fqn;
    LET rs1  RESULTSET := (EXECUTE IMMEDIATE :src_sql);
    LET cur1 CURSOR FOR rs1;
    OPEN cur1; FETCH cur1 INTO source_count; CLOSE cur1;
    LET rs2  RESULTSET := (EXECUTE IMMEDIATE :tgt_sql);
    LET cur2 CURSOR FOR rs2;
    OPEN cur2; FETCH cur2 INTO target_count; CLOSE cur2;
    IF (source_count > 0) THEN
        variance_pct := ABS(target_count - source_count)::FLOAT / source_count::FLOAT * 100;
    ELSE
        variance_pct := 0;
    END IF;
    RETURN OBJECT_CONSTRUCT(
        'source',       :source_fqn,
        'target',       :target_fqn,
        'source_count', :source_count,
        'target_count', :target_count,
        'variance_pct', :variance_pct,
        'pass',         (:variance_pct <= 5)
    )::VARCHAR;
EXCEPTION WHEN OTHER THEN
    RETURN OBJECT_CONSTRUCT('source', :source_fqn, 'target', :target_fqn, 'error', SQLERRM)::VARCHAR;
END;
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_QUERY_SAMPLE(
    fqn          VARCHAR,
    where_clause VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json

def run(session, fqn: str, where_clause: str) -> str:
    try:
        sql = f"SELECT * FROM {fqn} WHERE {where_clause} LIMIT 10"
        rows = session.sql(sql).collect()
        return json.dumps({"fqn": fqn, "where": where_clause,
                           "rows": [r.as_dict() for r in rows],
                           "count": len(rows)}, default=str)
    except Exception as e:
        return json.dumps({"fqn": fqn, "where": where_clause, "error": str(e)})
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_SAVE_PLANNER_DECISION(
    execution_id         VARCHAR,
    source_table         VARCHAR,
    transformation_strategy VARCHAR,
    pk_columns           VARCHAR,
    recommended_actions  VARCHAR,
    llm_reasoning        VARCHAR,
    confidence_score     FLOAT
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json, hashlib

def run(session, execution_id, source_table, transformation_strategy,
        pk_columns, recommended_actions, llm_reasoning, confidence_score):
    try:
        import uuid
        decision_id = str(uuid.uuid4())

        model_row = session.sql(
            "SELECT primary_model FROM AGENT_FRAMEWORK.MODEL_CONFIG WHERE config_key='default' LIMIT 1"
        ).collect()
        model_used = model_row[0][0] if model_row else 'agent'

        ctx_row = session.sql(
            "SELECT COALESCE(NULLIF(output_schema,''),'AGENT_FRAMEWORK_OUTPUT') "
            "FROM AGENT_FRAMEWORK.PIPELINE_CONTEXT WHERE context_id=1"
        ).collect()
        target_schema = ctx_row[0][0] if ctx_row else 'AGENT_FRAMEWORK_OUTPUT'

        fingerprint = hashlib.md5(
            (source_table + transformation_strategy + (pk_columns or '')).encode()
        ).hexdigest()

        session.sql(f"""
            INSERT INTO AGENT_FRAMEWORK.PLANNER_DECISIONS
                (decision_id, execution_id, source_table, target_schema,
                 transformation_strategy, recommended_actions, priority,
                 llm_reasoning, pk_columns, confidence_score,
                 model_used, schema_fingerprint)
            SELECT
                '{decision_id}',
                '{execution_id}',
                '{source_table}',
                '{target_schema}',
                '{transformation_strategy}',
                PARSE_JSON('{json.dumps(recommended_actions).replace("'", "''")}'),
                1,
                '{(llm_reasoning or '').replace("'", "''")}',
                '{(pk_columns or 'unknown')}',
                {float(confidence_score) if confidence_score else 0.7},
                '{model_used}',
                '{fingerprint}'
        """).collect()

        session.sql(f"""
            UPDATE AGENT_FRAMEWORK.TABLE_LINEAGE_MAP
            SET silver_status = 'PLANNED', updated_at = CURRENT_TIMESTAMP()
            WHERE UPPER(bronze_table) = UPPER(SPLIT_PART('{source_table}', '.', -1))
        """).collect()

        return json.dumps({
            "status": "SAVED",
            "decision_id": decision_id,
            "source_table": source_table,
            "strategy": transformation_strategy,
            "pk_columns": pk_columns
        })
    except Exception as e:
        return json.dumps({"status": "ERROR", "error": str(e)[:400]})
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_GET_PLANNER_DECISION(
    execution_id VARCHAR,
    table_name   VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json

def run(session, execution_id: str, table_name: str) -> str:
    rows = session.sql(
        "SELECT source_table, transformation_strategy, pk_columns, llm_reasoning, confidence_score "
        "FROM AGENT_FRAMEWORK.PLANNER_DECISIONS "
        "WHERE execution_id = ? AND UPPER(source_table) LIKE UPPER(?)",
        params=[execution_id, f"%{table_name}%"]
    ).collect()
    if rows:
        r = rows[0]
        return json.dumps({"table": r["SOURCE_TABLE"], "strategy": r["TRANSFORMATION_STRATEGY"],
                           "pk_columns": r["PK_COLUMNS"], "reasoning": r["LLM_REASONING"],
                           "confidence": r["CONFIDENCE_SCORE"]})
    return json.dumps({"table": table_name, "error": "No planner decision found for this execution"})
$$;

-- =============================================================================
-- REFLECTOR AGENT TOOLS
-- =============================================================================

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_SEARCH_LEARNINGS(query VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    LET result VARCHAR;
    CALL AGENT_FRAMEWORK.SEARCH_ATS_KNOWLEDGE(:query, 5) INTO :result;
    RETURN OBJECT_CONSTRUCT('query', :query, 'existing_learnings', :result)::VARCHAR;
END;
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_SAVE_LEARNING(
    execution_id    VARCHAR,
    observation     VARCHAR,
    recommendation  VARCHAR,
    confidence      FLOAT
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LEARNINGS (
        execution_id, learning_type, source_context,
        observation, recommendation, confidence_score, is_active
    )
    SELECT
        :execution_id,
        'SUCCESS',
        'v4_reflector',
        :observation,
        :recommendation,
        LEAST(1.0, GREATEST(0.0, :confidence)),
        TRUE;
    RETURN OBJECT_CONSTRUCT(
        'status',       'SAVED',
        'observation',  :observation,
        'confidence',   :confidence
    )::VARCHAR;
END;
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_GET_WORKFLOW_LOG(execution_id VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json

def run(session, execution_id: str) -> str:
    rows = session.sql(
        "SELECT phase, status, message, logged_at FROM AGENT_FRAMEWORK.WORKFLOW_LOG "
        "WHERE execution_id = ? ORDER BY logged_at ASC",
        params=[execution_id]
    ).collect()
    return json.dumps({"execution_id": execution_id, "log": [
        {"phase": r["PHASE"], "status": r["STATUS"], "message": r["MESSAGE"][:200],
         "at": str(r["LOGGED_AT"])}
        for r in rows
    ]})
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_GET_EXECUTOR_OUTPUT(execution_id VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json

def run(session, execution_id: str) -> str:
    rows = session.sql(
        "SELECT executor_output FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS "
        "WHERE execution_id = ?",
        params=[execution_id]
    ).collect()
    if rows and rows[0]["EXECUTOR_OUTPUT"]:
        raw = rows[0]["EXECUTOR_OUTPUT"]
        return json.dumps({"execution_id": execution_id, "executor_output": raw}, default=str)
    return json.dumps({"execution_id": execution_id, "error": "No executor output found"})
$$;

-- =============================================================================
-- ORCHESTRATOR AGENT TOOLS
-- =============================================================================

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_CREATE_EXECUTION(
    trigger_source VARCHAR,
    tables_json    VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json, uuid

def run(session, trigger_source: str, tables_json: str) -> str:
    execution_id = str(uuid.uuid4())
    try:
        tables = json.loads(tables_json) if tables_json else None
    except Exception:
        tables = None

    if not tables:
        rows = session.sql(
            "SELECT ARRAY_AGG(bronze_database || '.' || bronze_schema || '.' || bronze_table) AS t "
            "FROM AGENT_FRAMEWORK.SILVER_GAPS LIMIT 50"
        ).collect()
        tables = rows[0]["T"] if rows and rows[0]["T"] else []

    session.sql(
        "INSERT INTO AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS "
        "(execution_id, workflow_name, trigger_source, trigger_type, status, tables_requested) "
        "VALUES (?, 'SILVER_BUILDER_V4', ?, 'AUTOMATED', 'PENDING', PARSE_JSON(?))",
        params=[execution_id, trigger_source, json.dumps(tables)]
    ).collect()
    return json.dumps({"execution_id": execution_id, "tables": tables,
                       "trigger_source": trigger_source})
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_GET_WORKFLOW_STATUS(execution_id VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json

def run(session, execution_id: str) -> str:
    rows = session.sql(
        "SELECT status, current_phase, tables_requested, execution_started_at, execution_completed_at "
        "FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS WHERE execution_id = ?",
        params=[execution_id]
    ).collect()
    if rows:
        r = rows[0]
        return json.dumps({"execution_id": execution_id, "status": r["STATUS"],
                           "phase": r["CURRENT_PHASE"],
                           "started_at": str(r["EXECUTION_STARTED_AT"])}, default=str)
    return json.dumps({"execution_id": execution_id, "error": "Execution not found"})
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_UPDATE_WORKFLOW_STATUS(
    execution_id VARCHAR,
    phase        VARCHAR,
    status       VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    UPDATE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
    SET current_phase = :phase,
        status        = :status,
        execution_completed_at = CASE WHEN :status IN ('COMPLETE','ERROR','FAILED')
                                       THEN CURRENT_TIMESTAMP() ELSE execution_completed_at END
    WHERE execution_id = :execution_id;
    RETURN OBJECT_CONSTRUCT('execution_id', :execution_id, 'phase', :phase,
                            'status', :status)::VARCHAR;
END;
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_LOG_WORKFLOW_EVENT(
    execution_id VARCHAR,
    phase        VARCHAR,
    status       VARCHAR,
    message      VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
    VALUES (:execution_id, :phase, :status, :message);
    RETURN OBJECT_CONSTRUCT('logged', TRUE, 'phase', :phase, 'status', :status)::VARCHAR;
END;
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_LIST_SILVER_GAPS()
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json

def run(session) -> str:
    rows = session.sql(
        "SELECT bronze_database, bronze_schema, bronze_table, "
        "bronze_database || '.' || bronze_schema || '.' || bronze_table AS fqn "
        "FROM AGENT_FRAMEWORK.SILVER_GAPS ORDER BY bronze_table"
    ).collect()
    return json.dumps({"gaps": [{"fqn": r["FQN"], "table": r["BRONZE_TABLE"]} for r in rows],
                       "count": len(rows)})
$$;

-- Bridge tools — call v3 SPs so Orchestrator can chain phases
-- during the transition period while sub-agents are being built

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_RUN_SCHEMA_ANALYST(execution_id VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE result VARIANT;
BEGIN
    result := (CALL AGENT_FRAMEWORK.WORKFLOW_SCHEMA_ANALYST(:execution_id));
    RETURN result::VARCHAR;
END;
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_RUN_PLANNER(execution_id VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE result VARIANT;
BEGIN
    result := (CALL AGENT_FRAMEWORK.WORKFLOW_PLANNER(:execution_id));
    RETURN result::VARCHAR;
END;
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_RUN_EXECUTOR(execution_id VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE result VARIANT;
BEGIN
    result := (CALL AGENT_FRAMEWORK.WORKFLOW_EXECUTOR(:execution_id));
    RETURN result::VARCHAR;
END;
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_RUN_VALIDATOR(execution_id VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE result VARIANT;
BEGIN
    result := (CALL AGENT_FRAMEWORK.WORKFLOW_VALIDATOR(:execution_id));
    RETURN result::VARCHAR;
END;
$$;

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.ATS_TOOL_RUN_REFLECTOR(execution_id VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE result VARIANT;
BEGIN
    result := (CALL AGENT_FRAMEWORK.WORKFLOW_REFLECTOR(:execution_id));
    RETURN result::VARCHAR;
END;
$$;
