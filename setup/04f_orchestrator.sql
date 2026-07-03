-- =============================================================================
-- 04f_orchestrator.sql
-- RUN_AGENTIC_WORKFLOW: Chains all five phases in sequence.
-- Used for CLI/Task-scheduled runs. Streamlit calls each phase individually.
-- =============================================================================

USE DATABASE IDENTIFIER($TARGET_DB);

-- Drop old signatures to avoid DEFAULT overload ambiguity
DROP PROCEDURE IF EXISTS AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW(VARCHAR, ARRAY);

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW(
    trigger_source VARCHAR DEFAULT 'manual',
    tables_list    ARRAY   DEFAULT NULL,
    p_trigger_type VARCHAR DEFAULT 'MANUAL'
)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    execution_id     VARCHAR DEFAULT UUID_STRING();
    resolved_tables  ARRAY;
    analyst_result   VARIANT;
    planner_result   VARIANT;
    executor_result  VARIANT;
    validator_result VARIANT;
    reflector_result VARIANT;
BEGIN
    IF (tables_list IS NOT NULL) THEN
        resolved_tables := tables_list;
    ELSE
        -- When overwrite_existing=TRUE, include all registered tables;
        -- otherwise only tables with no Silver coverage yet (SILVER_GAPS).
        LET overwrite_flag BOOLEAN DEFAULT FALSE;
        SELECT COALESCE(overwrite_existing, FALSE)
            INTO :overwrite_flag
            FROM AGENT_FRAMEWORK.PIPELINE_CONTEXT
            WHERE context_id = 1;

        IF (:overwrite_flag) THEN
            SELECT ARRAY_AGG(
                bronze_database || '.' || bronze_schema || '.' || bronze_table
            ) INTO :resolved_tables
            FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP
            LIMIT 50;
        ELSE
            SELECT ARRAY_AGG(
                bronze_database || '.' || bronze_schema || '.' || bronze_table
            ) INTO :resolved_tables
            FROM AGENT_FRAMEWORK.SILVER_GAPS
            LIMIT 50;
        END IF;
    END IF;

    INSERT INTO AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS (
        execution_id, workflow_name, trigger_source, trigger_type,
        status, tables_requested
    )
    SELECT :execution_id, 'SILVER_BUILDER', :trigger_source, UPPER(:p_trigger_type),
           'PENDING', :resolved_tables;

    analyst_result   := (CALL AGENT_FRAMEWORK.WORKFLOW_SCHEMA_ANALYST(:execution_id));
    planner_result   := (CALL AGENT_FRAMEWORK.WORKFLOW_PLANNER(:execution_id));
    executor_result  := (CALL AGENT_FRAMEWORK.WORKFLOW_EXECUTOR(:execution_id));
    validator_result := (CALL AGENT_FRAMEWORK.WORKFLOW_VALIDATOR(:execution_id));
    reflector_result := (CALL AGENT_FRAMEWORK.WORKFLOW_REFLECTOR(:execution_id));

    RETURN OBJECT_CONSTRUCT(
        'execution_id', execution_id,
        'analyst',      analyst_result,
        'planner',      planner_result,
        'executor',     executor_result,
        'validator',    validator_result,
        'reflector',    reflector_result
    );

EXCEPTION WHEN OTHER THEN
    LET captured_error VARCHAR := SQLERRM;
    UPDATE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
    SET status       = 'FAILED',
        last_error   = :captured_error,
        completed_at = CURRENT_TIMESTAMP()
    WHERE execution_id = :execution_id;
    RAISE;
END;
$$;
