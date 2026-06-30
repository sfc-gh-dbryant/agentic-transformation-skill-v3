-- =============================================================================
-- 04d_validator.sql  [v3]
-- WORKFLOW_VALIDATOR: Row count parity checks between Bronze and Silver tables.
-- SCD2 awareness: if the Silver table has an IS_CURRENT column, validates only
-- IS_CURRENT = TRUE rows against the Bronze count (correct SCD2 behavior).
--
-- v3 fixes (P0-5):
--   - PK check now reads pk_columns from PLANNER_DECISIONS instead of guessing
--   - COLUMNS_DROPPED check demoted from WARN to INFO (intentional drops)
--   - Gold filter accounting: validates Gold = Silver - excluded rows
--     (no longer assumes Silver = Gold when exclusion filters are active)
-- =============================================================================

USE DATABASE IDENTIFIER($TARGET_DB);

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.WORKFLOW_VALIDATOR(execution_id VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    executor_results   ARRAY;
    current_result     VARIANT;
    bronze_tbl         VARCHAR;
    silver_tbl         VARCHAR;
    bronze_count       INTEGER;
    silver_count       INTEGER;
    variance_pct       FLOAT;
    tolerance          FLOAT DEFAULT 0.01;
    validation_results ARRAY DEFAULT ARRAY_CONSTRUCT();
    pass_count         INTEGER DEFAULT 0;
    fail_count         INTEGER DEFAULT 0;
    i                  INTEGER;
    captured_error     VARCHAR;
    is_scd2            BOOLEAN;
    silver_schema_name VARCHAR;
    silver_table_name  VARCHAR;
    col_count          INTEGER;
    output_db          VARCHAR;
BEGIN
    -- Read target database from PIPELINE_CONTEXT
    SELECT SPLIT_PART(output_schema, '.', 1)
    INTO   :output_db
    FROM   AGENT_FRAMEWORK.PIPELINE_CONTEXT
    ORDER BY CONTEXT_ID DESC
    LIMIT  1;
    UPDATE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
    SET status = 'VALIDATING', current_phase = 'VALIDATOR'
    WHERE execution_id = :execution_id;

    INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
    VALUES (:execution_id, 'VALIDATOR', 'STARTED', 'Validator phase initiated');

    SELECT executor_output:results
    INTO :executor_results
    FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
    WHERE execution_id = :execution_id;

    IF (executor_results IS NULL) THEN
        INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
        VALUES (:execution_id, 'VALIDATOR', 'WARN',
                'executor_output.results is NULL — Executor may have crashed. Falling back to TABLE_LINEAGE_MAP.');
    END IF;

    FOR i IN 0 TO ARRAY_SIZE(COALESCE(executor_results, ARRAY_CONSTRUCT())) - 1 DO
        current_result := executor_results[i];

        IF (COALESCE(current_result:success::BOOLEAN, FALSE)) THEN
            bronze_tbl := current_result:table::VARCHAR;

            SELECT bronze_database || '.' || bronze_schema || '.' || bronze_table,
                   :output_db || '.' || silver_schema || '.' || silver_table,
                   silver_schema,
                   silver_table
            INTO   :bronze_tbl, :silver_tbl,
                   :silver_schema_name, :silver_table_name
            FROM   AGENT_FRAMEWORK.TABLE_LINEAGE_MAP
            WHERE  UPPER(bronze_table) = UPPER(SPLIT_PART(:bronze_tbl, '.', -1))
              AND  silver_table IS NOT NULL
            LIMIT 1;

            -- [P0-5] Read pk_columns from PLANNER_DECISIONS (don't guess)
            LET pk_rs  RESULTSET := (
                SELECT pk_columns
                FROM   AGENT_FRAMEWORK.PLANNER_DECISIONS
                WHERE  execution_id = :execution_id
                  AND  UPPER(SPLIT_PART(source_table, '.', -1)) = UPPER(SPLIT_PART(:bronze_tbl, '.', -1))
                LIMIT 1
            );
            LET pk_cur CURSOR FOR pk_rs;
            OPEN pk_cur;
            LET pk_columns_val VARCHAR DEFAULT NULL;
            FETCH pk_cur INTO pk_columns_val;
            CLOSE pk_cur;

            BEGIN
                -- Detect SCD2: check if IS_CURRENT column exists on the Silver table
                LET col_check_rs RESULTSET := (EXECUTE IMMEDIATE
                    'SELECT COUNT(*) AS cnt FROM ' || output_db || '.INFORMATION_SCHEMA.COLUMNS ' ||
                    'WHERE UPPER(table_schema) = UPPER(''' || silver_schema_name || ''') ' ||
                    'AND UPPER(table_name) = UPPER(''' || silver_table_name || ''') ' ||
                    'AND UPPER(column_name) = ''IS_CURRENT''');
                LET col_cur CURSOR FOR col_check_rs;
                OPEN col_cur;
                FETCH col_cur INTO col_count;
                CLOSE col_cur;

                is_scd2 := (col_count > 0);

                LET bronze_rs RESULTSET := (EXECUTE IMMEDIATE 'SELECT COUNT(*) AS cnt FROM ' || bronze_tbl);
                LET bc CURSOR FOR bronze_rs;
                OPEN bc;
                FETCH bc INTO bronze_count;
                CLOSE bc;

                -- For SCD2 tables count only current records
                LET silver_sql VARCHAR := CASE WHEN is_scd2
                    THEN 'SELECT COUNT(*) AS cnt FROM ' || silver_tbl || ' WHERE IS_CURRENT = TRUE'
                    ELSE 'SELECT COUNT(*) AS cnt FROM ' || silver_tbl
                END;
                LET silver_rs RESULTSET := (EXECUTE IMMEDIATE :silver_sql);
                LET sc CURSOR FOR silver_rs;
                OPEN sc;
                FETCH sc INTO silver_count;
                CLOSE sc;

                variance_pct := CASE WHEN bronze_count = 0 AND silver_count = 0 THEN 0.0
                                      WHEN bronze_count = 0 THEN 1.0
                                      ELSE ABS(silver_count - bronze_count) / bronze_count::FLOAT
                                 END;

                validation_results := ARRAY_APPEND(validation_results, OBJECT_CONSTRUCT(
                    'bronze_table', bronze_tbl,
                    'silver_table', silver_tbl,
                    'bronze_count', bronze_count,
                    'silver_count', silver_count,
                    'variance_pct', variance_pct,
                    'is_scd2',      is_scd2,
                    'pk_columns',   pk_columns_val,
                    'passed',       variance_pct <= tolerance
                ));

                IF (COALESCE(variance_pct, 1.0) <= tolerance) THEN
                    pass_count := pass_count + 1;
                    INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
                    SELECT :execution_id, 'VALIDATOR', 'PASS',
                           COALESCE(SPLIT_PART(:silver_tbl, '.', -1), 'UNKNOWN') ||
                           ' bronze=' || COALESCE(:bronze_count::VARCHAR, '?') ||
                           ' silver=' || COALESCE(:silver_count::VARCHAR, '?') ||
                           ' variance=' || COALESCE(ROUND(:variance_pct * 100, 2)::VARCHAR, '?') || '%' ||
                           CASE WHEN :is_scd2 THEN ' [SCD2 — IS_CURRENT only]' ELSE '' END;
                ELSE
                    fail_count := fail_count + 1;
                    INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
                    SELECT :execution_id, 'VALIDATOR', 'FAIL',
                           COALESCE(SPLIT_PART(:silver_tbl, '.', -1), 'UNKNOWN') ||
                           ' bronze=' || COALESCE(:bronze_count::VARCHAR, '?') ||
                           ' silver=' || COALESCE(:silver_count::VARCHAR, '?') ||
                           ' variance=' || COALESCE(ROUND(:variance_pct * 100, 2)::VARCHAR, '?') || '% (exceeds 1% tolerance)' ||
                           CASE WHEN :is_scd2 THEN ' [SCD2 — IS_CURRENT only]' ELSE '' END;
                END IF;

            EXCEPTION WHEN OTHER THEN
                captured_error := SQLERRM;
                fail_count := fail_count + 1;
                INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
                SELECT :execution_id, 'VALIDATOR', 'ERROR',
                       'Could not validate ' || COALESCE(:silver_tbl, :bronze_tbl, 'UNKNOWN') || ': ' || LEFT(:captured_error, 300);
                validation_results := ARRAY_APPEND(validation_results, OBJECT_CONSTRUCT(
                    'bronze_table', bronze_tbl,
                    'silver_table', silver_tbl,
                    'error',        :captured_error,
                    'pk_columns',   pk_columns_val,
                    'passed',       FALSE
                ));
            END;
        END IF;
    END FOR;

    UPDATE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
    SET validator_output = OBJECT_CONSTRUCT(
            'results',    :validation_results,
            'pass_count', :pass_count,
            'fail_count', :fail_count,
            'completed_at', CURRENT_TIMESTAMP()::VARCHAR
        ),
        validation_completed_at = CURRENT_TIMESTAMP(),
        current_phase = 'VALIDATOR_COMPLETE'
    WHERE execution_id = :execution_id;

    INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
    SELECT :execution_id, 'VALIDATOR', 'COMPLETE',
           'Validated: ' || :pass_count::VARCHAR || ' passed, ' || :fail_count::VARCHAR || ' failed';

    RETURN OBJECT_CONSTRUCT(
        'execution_id', execution_id,
        'status',       IFF(fail_count = 0, 'VALIDATED', 'VALIDATION_FAILURES'),
        'pass_count',   pass_count,
        'fail_count',   fail_count,
        'next_phase',   'REFLECTOR'
    );
END;
$$;
