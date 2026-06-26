-- =============================================================================
-- 04e_reflector.sql
-- WORKFLOW_REFLECTOR: LLM post-mortem. Extracts learnings and MERGEs into WORKFLOW_LEARNINGS.
-- Always runs regardless of executor/validator outcome.
-- =============================================================================

USE DATABASE IDENTIFIER($TARGET_DB);

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.WORKFLOW_REFLECTOR(execution_id VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    active_model       VARCHAR;
    workflow_data      VARIANT;
    reflection_prompt  VARCHAR;
    llm_reflection     VARCHAR;
    parsed_learnings   VARIANT;
    learnings_array    ARRAY;
    i                  INTEGER;
    learning           VARIANT;
BEGIN
    SELECT primary_model INTO :active_model
    FROM AGENT_FRAMEWORK.MODEL_CONFIG
    WHERE config_key = 'default' LIMIT 1;

    UPDATE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
    SET status = 'REFLECTING', current_phase = 'REFLECTOR'
    WHERE execution_id = :execution_id;

    INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
    VALUES (:execution_id, 'REFLECTOR', 'STARTED', 'Reflector phase initiated. Model: ' || :active_model);

    SELECT OBJECT_CONSTRUCT(
        'execution_id',       execution_id,
        'planner_output',     planner_output,
        'executor_results',   executor_output,
        'validation_results', validator_output
    ) INTO :workflow_data
    FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
    WHERE execution_id = :execution_id;

    reflection_prompt := 'You are the REFLECTOR agent. Analyze this completed workflow and extract reusable learnings.

WORKFLOW SUMMARY:
' || workflow_data::VARCHAR || '

TASKS:
1. Identify successful patterns to be reused in future runs
2. Identify failures and their root causes
3. Suggest specific optimizations for similar tables

OUTPUT FORMAT (JSON array only, no explanation, no markdown):
[
  {
    "learning_type": "success_pattern|failure_pattern|optimization",
    "pattern_signature": "unique_identifier_for_dedup",
    "source_context": "table_or_pattern_this_applies_to",
    "observation": "what was observed",
    "recommendation": "specific actionable recommendation",
    "confidence": 0.0-1.0
  }
]';

    SELECT SNOWFLAKE.CORTEX.COMPLETE(:active_model, :reflection_prompt) INTO :llm_reflection;

    BEGIN
        parsed_learnings := PARSE_JSON(REGEXP_SUBSTR(llm_reflection, '\\[.*\\]', 1, 1, 'ms'));
        learnings_array  := parsed_learnings;
    EXCEPTION WHEN OTHER THEN
        learnings_array := ARRAY_CONSTRUCT(OBJECT_CONSTRUCT(
            'learning_type',     'reflection_error',
            'pattern_signature', 'parse_error_' || execution_id,
            'source_context',    'workflow',
            'observation',       'Could not parse reflection output',
            'recommendation',    'Review raw LLM output for this execution',
            'confidence',        0.2
        ));
    END;

    FOR i IN 0 TO ARRAY_SIZE(COALESCE(learnings_array, ARRAY_CONSTRUCT())) - 1 DO
        learning := learnings_array[i];

        MERGE INTO AGENT_FRAMEWORK.WORKFLOW_LEARNINGS t
        USING (
            SELECT
                :execution_id                         AS execution_id,
                :learning:learning_type::VARCHAR      AS learning_type,
                :learning:source_context::VARCHAR     AS source_context,
                :learning:pattern_signature::VARCHAR  AS pattern_signature,
                :learning:observation::VARCHAR        AS observation,
                :learning:recommendation::VARCHAR     AS recommendation,
                :learning:confidence::FLOAT           AS confidence_score
        ) s ON (t.pattern_signature = s.pattern_signature AND t.is_active = TRUE)
        WHEN MATCHED THEN
            UPDATE SET
                times_observed   = t.times_observed + 1,
                confidence_score = LEAST((t.confidence_score + s.confidence_score) / 2.0 + 0.05, 1.0),
                observation      = s.observation,
                recommendation   = s.recommendation,
                last_observed_at = CURRENT_TIMESTAMP()
        WHEN NOT MATCHED THEN
            INSERT (execution_id, learning_type, source_context, pattern_signature,
                    observation, recommendation, confidence_score)
            VALUES (s.execution_id, s.learning_type, s.source_context, s.pattern_signature,
                    s.observation, s.recommendation, s.confidence_score);
    END FOR;

    UPDATE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
    SET reflector_output = OBJECT_CONSTRUCT(
            'learnings_processed', ARRAY_SIZE(:learnings_array),
            'model_used',          :active_model,
            'completed_at',        CURRENT_TIMESTAMP()::VARCHAR
        ),
        reflection_completed_at = CURRENT_TIMESTAMP(),
        status        = 'COMPLETE',
        completed_at  = CURRENT_TIMESTAMP(),
        current_phase = 'COMPLETE'
    WHERE execution_id = :execution_id;

    INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
    SELECT :execution_id, 'REFLECTOR', 'COMPLETE',
           'Processed ' || ARRAY_SIZE(:learnings_array)::VARCHAR || ' learnings';

    RETURN OBJECT_CONSTRUCT(
        'execution_id',        execution_id,
        'status',              'COMPLETE',
        'learnings_processed', ARRAY_SIZE(learnings_array),
        'model_used',          active_model
    );
END;
$$;
