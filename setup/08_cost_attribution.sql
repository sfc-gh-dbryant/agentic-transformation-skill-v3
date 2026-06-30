-- 08_cost_attribution.sql
-- WORKFLOW_COST_ATTRIBUTION table + CAPTURE_WORKFLOW_COST SP
-- =============================================================================

USE DATABASE IDENTIFIER($TARGET_DB);
USE SCHEMA AGENT_FRAMEWORK;

CREATE TABLE IF NOT EXISTS AGENT_FRAMEWORK.WORKFLOW_COST_ATTRIBUTION (
    attribution_id      VARCHAR       DEFAULT UUID_STRING()    PRIMARY KEY,
    execution_id        VARCHAR       NOT NULL,
    captured_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    warehouse_name      VARCHAR,
    warehouse_credits   FLOAT         DEFAULT 0,
    cortex_credits      FLOAT         DEFAULT 0,
    cortex_tokens       INTEGER       DEFAULT 0,
    total_credits       FLOAT         DEFAULT 0,
    query_count         INTEGER       DEFAULT 0,
    llm_call_count      INTEGER       DEFAULT 0,
    retry_llm_calls     INTEGER       DEFAULT 0,
    cost_per_table      FLOAT,
    tables_built        INTEGER       DEFAULT 0,
    phase_breakdown     VARIANT,
    cortex_data_lag     VARCHAR       DEFAULT 'UP_TO_45_MIN_DELAY'
);

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.CAPTURE_WORKFLOW_COST(execution_id VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    run_start       TIMESTAMP_NTZ;
    run_end         TIMESTAMP_NTZ;
    wh_name         VARCHAR;
    wh_credits      FLOAT DEFAULT 0;
    cx_credits      FLOAT DEFAULT 0;
    cx_tokens       INTEGER DEFAULT 0;
    q_count         INTEGER DEFAULT 0;
    llm_calls       INTEGER DEFAULT 0;
    retry_calls     INTEGER DEFAULT 0;
    tables_built    INTEGER DEFAULT 0;
    cost_per_tbl    FLOAT;
    phase_json      VARIANT;
BEGIN
    -- Get execution window and warehouse
    SELECT started_at, COALESCE(completed_at, CURRENT_TIMESTAMP()),
           m.primary_model
    INTO   :run_start, :run_end, :wh_name
    FROM   AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS e,
           AGENT_FRAMEWORK.MODEL_CONFIG m
    WHERE  e.execution_id = :execution_id
      AND  m.config_key = 'default'
    LIMIT  1;

    -- Get warehouse name from pipeline context
    SELECT COALESCE(warehouse, 'UNKNOWN')
    INTO   :wh_name
    FROM   AGENT_FRAMEWORK.MODEL_CONFIG
    WHERE  config_key = 'default'
    LIMIT  1;

    -- Warehouse credits: query INFORMATION_SCHEMA (near real-time, 7-day window)
    BEGIN
        LET wh_rs RESULTSET := (EXECUTE IMMEDIATE
            'SELECT COALESCE(SUM(CREDITS_USED_CLOUD_SERVICES), 0) AS credits,
                    COUNT(*) AS q_count
             FROM   TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_WAREHOUSE(
                        WAREHOUSE_NAME => ''' || :wh_name || ''',
                        END_TIME_RANGE_START => ''' || :run_start::VARCHAR || '''::TIMESTAMP_NTZ,
                        END_TIME_RANGE_END   => ''' || :run_end::VARCHAR   || '''::TIMESTAMP_NTZ
                    ))'
        );
        LET wh_cur CURSOR FOR wh_rs;
        OPEN wh_cur; FETCH wh_cur INTO wh_credits, q_count; CLOSE wh_cur;
    EXCEPTION WHEN OTHER THEN
        wh_credits := 0; q_count := 0;
    END;

    -- Cortex LLM credits: ACCOUNT_USAGE (up to 45-min delay)
    BEGIN
        LET cx_rs RESULTSET := (EXECUTE IMMEDIATE
            'SELECT COALESCE(SUM(TOKEN_CREDITS), 0),
                    COALESCE(SUM(TOKENS), 0),
                    COUNT(*)
             FROM   SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY
             WHERE  START_TIME >= ''' || :run_start::VARCHAR || '''::TIMESTAMP_NTZ
               AND  END_TIME   <= DATEADD(''hour'', 1, ''' || :run_end::VARCHAR || '''::TIMESTAMP_NTZ)'
        );
        LET cx_cur CURSOR FOR cx_rs;
        OPEN cx_cur; FETCH cx_cur INTO cx_credits, cx_tokens, llm_calls; CLOSE cx_cur;
    EXCEPTION WHEN OTHER THEN
        cx_credits := 0; cx_tokens := 0; llm_calls := 0;
    END;

    -- Retry LLM calls (each retry = extra LLM call)
    SELECT COUNT(*) INTO :retry_calls
    FROM   AGENT_FRAMEWORK.WORKFLOW_LOG
    WHERE  execution_id = :execution_id
      AND  phase = 'EXECUTOR'
      AND  status = 'RETRY';

    -- Tables built
    SELECT COALESCE(executor_output:success_count::INT, 0)
    INTO   :tables_built
    FROM   AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
    WHERE  execution_id = :execution_id;

    -- Cost per table
    cost_per_tbl := CASE WHEN tables_built > 0
                         THEN (wh_credits + cx_credits) / tables_built
                         ELSE NULL END;

    -- Per-phase breakdown using phase timestamps
    BEGIN
        LET ph_rs RESULTSET := (EXECUTE IMMEDIATE '
            SELECT OBJECT_CONSTRUCT(
                ''schema_analyst'', OBJECT_CONSTRUCT(
                    ''duration_sec'', DATEDIFF(''second'', started_at, COALESCE(schema_analyst_completed_at, started_at)),
                    ''end_time'',     COALESCE(schema_analyst_completed_at::VARCHAR, ''—'')
                ),
                ''planner'', OBJECT_CONSTRUCT(
                    ''duration_sec'', DATEDIFF(''second'',
                        COALESCE(schema_analyst_completed_at, started_at),
                        COALESCE(planning_completed_at, schema_analyst_completed_at, started_at))
                ),
                ''executor'', OBJECT_CONSTRUCT(
                    ''duration_sec'', DATEDIFF(''second'',
                        COALESCE(planning_completed_at, started_at),
                        COALESCE(execution_completed_at, planning_completed_at, started_at))
                ),
                ''validator'', OBJECT_CONSTRUCT(
                    ''duration_sec'', DATEDIFF(''second'',
                        COALESCE(execution_completed_at, started_at),
                        COALESCE(validation_completed_at, execution_completed_at, started_at))
                ),
                ''reflector'', OBJECT_CONSTRUCT(
                    ''duration_sec'', DATEDIFF(''second'',
                        COALESCE(validation_completed_at, started_at),
                        COALESCE(reflection_completed_at, validation_completed_at, started_at))
                ),
                ''total_sec'', DATEDIFF(''second'', started_at, COALESCE(completed_at, CURRENT_TIMESTAMP()))
            )
            FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
            WHERE execution_id = ''' || :execution_id || ''''
        );
        LET ph_cur CURSOR FOR ph_rs;
        OPEN ph_cur; FETCH ph_cur INTO phase_json; CLOSE ph_cur;
    EXCEPTION WHEN OTHER THEN
        phase_json := NULL;
    END;

    -- Upsert cost record
    MERGE INTO AGENT_FRAMEWORK.WORKFLOW_COST_ATTRIBUTION t
    USING (SELECT :execution_id AS eid) s ON t.execution_id = s.eid
    WHEN MATCHED THEN UPDATE SET
        captured_at       = CURRENT_TIMESTAMP(),
        warehouse_credits = :wh_credits,
        cortex_credits    = :cx_credits,
        cortex_tokens     = :cx_tokens,
        total_credits     = :wh_credits + :cx_credits,
        query_count       = :q_count,
        llm_call_count    = :llm_calls,
        retry_llm_calls   = :retry_calls,
        cost_per_table    = :cost_per_tbl,
        tables_built      = :tables_built,
        phase_breakdown   = :phase_json
    WHEN NOT MATCHED THEN INSERT
        (execution_id, warehouse_credits, cortex_credits, cortex_tokens,
         total_credits, query_count, llm_call_count, retry_llm_calls,
         cost_per_table, tables_built, phase_breakdown)
    VALUES
        (:execution_id, :wh_credits, :cx_credits, :cx_tokens,
         :wh_credits + :cx_credits, :q_count, :llm_calls, :retry_calls,
         :cost_per_tbl, :tables_built, :phase_json);

    RETURN OBJECT_CONSTRUCT(
        'execution_id',      :execution_id,
        'warehouse_credits', :wh_credits,
        'cortex_credits',    :cx_credits,
        'cortex_tokens',     :cx_tokens,
        'total_credits',     :wh_credits + :cx_credits,
        'tables_built',      :tables_built,
        'cost_per_table',    :cost_per_tbl,
        'retry_llm_calls',   :retry_calls
    );
END;
$$;
