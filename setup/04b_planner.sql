USE DATABASE IDENTIFIER($TARGET_DB);

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.WORKFLOW_PLANNER(execution_id VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    active_model         VARCHAR;
    tables_to_process    ARRAY;
    tables_to_plan       ARRAY   DEFAULT ARRAY_CONSTRUCT();
    existing_learnings   VARCHAR;
    pipeline_context     VARCHAR;
    contracts_context    TEXT;
    all_decisions        ARRAY   DEFAULT ARRAY_CONSTRUCT();
    skipped_count        INTEGER DEFAULT 0;
    planned_count        INTEGER DEFAULT 0;
    -- Dynamic batching
    token_budget         INTEGER DEFAULT 6000;
    base_overhead        INTEGER DEFAULT 900;
    batch_tables_list    TEXT    DEFAULT '';
    batch_token_count    INTEGER DEFAULT 0;
    batch_start_idx      INTEGER DEFAULT 0;
    -- Per-table state
    i                    INTEGER DEFAULT 0;
    j                    INTEGER DEFAULT 0;
    n                    INTEGER DEFAULT 0;
    current_table        VARCHAR;
    extract_table        VARCHAR;
    extract_key          VARCHAR;
    extract_fp           VARCHAR;
    schema_info          VARIANT;
    schema_info_ext      VARIANT;
    directives_context   TEXT;
    relationship_context TEXT;
    inbound_fk_count     INTEGER;
    table_block          TEXT;
    this_table_tokens    INTEGER;
    current_schema_fp    VARCHAR;
    fire_batch           BOOLEAN DEFAULT FALSE;
    -- LLM
    batch_prompt         VARCHAR;
    llm_response         VARCHAR;
    parsed_batch         VARIANT;
    parsed_plan          VARIANT;
    -- JSON parser
    obj_start            INTEGER;
    obj_end              INTEGER;
    depth                INTEGER;
    pos                  INTEGER;
    rlen                 INTEGER;
    cached_count         INTEGER;
BEGIN
    SELECT primary_model INTO :active_model
    FROM AGENT_FRAMEWORK.MODEL_CONFIG
    WHERE config_key = 'default' LIMIT 1;

    UPDATE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
    SET status = 'PLANNING', current_phase = 'PLANNER'
    WHERE execution_id = :execution_id;

    INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
    VALUES (:execution_id, 'PLANNER', 'STARTED',
            'Planner v3 (dynamic batching + schema-hash cache). Model: ' || :active_model);

    SELECT tables_requested INTO :tables_to_process
    FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
    WHERE execution_id = :execution_id;

    SELECT LISTAGG(observation || ' -> ' || recommendation, '; ')
    INTO :existing_learnings
    FROM AGENT_FRAMEWORK.WORKFLOW_LEARNINGS
    WHERE is_active = TRUE AND confidence_score > 0.7
    LIMIT 5;

    -- Enhance learnings with Cortex Search if service exists
    -- Falls back silently to the LISTAGG result if search service not deployed
    BEGIN
        LET table_names VARCHAR := ARRAY_TO_STRING(
            ARRAY_SLICE(tables_to_process, 0, 5), ', '
        );
        LET search_result VARCHAR DEFAULT NULL;
        CALL AGENT_FRAMEWORK.SEARCH_ATS_KNOWLEDGE(
            'transformation strategy for tables: ' || :table_names, 8
        ) INTO :search_result;
        IF (search_result IS NOT NULL AND search_result != 'No prior knowledge found.') THEN
            existing_learnings := search_result ||
                CASE WHEN existing_learnings IS NOT NULL
                     THEN chr(10) || '---' || chr(10) || existing_learnings
                     ELSE '' END;
        END IF;
    EXCEPTION WHEN OTHER THEN
        NULL; -- Search service not deployed yet, use LISTAGG learnings as-is
    END;

    SELECT AGENT_FRAMEWORK.PIPELINE_CONTEXT_AS_PROMPT() INTO :pipeline_context;
    contracts_context := AGENT_FRAMEWORK.CONTRACTS_AS_PROMPT_CONTEXT('SILVER');

    -- ── Schema-hash skip-unchanged pass ──────────────────────────────────────
    FOR i IN 0 TO ARRAY_SIZE(tables_to_process) - 1 DO
        current_table     := tables_to_process[i]::VARCHAR;
        schema_info       := (CALL AGENT_FRAMEWORK.DISCOVER_SCHEMA(:current_table));
        current_schema_fp := MD5(schema_info::VARCHAR);

        SELECT COUNT(*) INTO :cached_count
        FROM AGENT_FRAMEWORK.PLANNER_DECISIONS pd
        JOIN AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS we ON pd.execution_id = we.execution_id
        WHERE UPPER(pd.source_table)  = UPPER(:current_table)
          AND pd.confidence_score    >= 0.85
          AND pd.schema_fingerprint   = :current_schema_fp
          AND we.status               = 'COMPLETED';

        IF (:cached_count > 0) THEN
            INSERT INTO AGENT_FRAMEWORK.PLANNER_DECISIONS
                (execution_id, source_table, target_schema, transformation_strategy,
                 detected_patterns, recommended_actions, priority, llm_reasoning,
                 confidence_score, model_used, schema_fingerprint)
            SELECT :execution_id, source_table, target_schema, transformation_strategy,
                   detected_patterns, recommended_actions, priority,
                   '[REUSED — schema unchanged] ' || llm_reasoning,
                   confidence_score, model_used, :current_schema_fp
            FROM AGENT_FRAMEWORK.PLANNER_DECISIONS pd
            JOIN AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS we ON pd.execution_id = we.execution_id
            WHERE UPPER(pd.source_table)  = UPPER(:current_table)
              AND pd.confidence_score    >= 0.85
              AND pd.schema_fingerprint   = :current_schema_fp
              AND we.status               = 'COMPLETED'
            ORDER BY we.completed_at DESC
            LIMIT 1;

            skipped_count := skipped_count + 1;

            INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
            VALUES (:execution_id, 'PLANNER', 'CACHE_HIT',
                    SPLIT_PART(:current_table, '.', -1) || ' -> schema unchanged, reused');
        ELSE
            tables_to_plan := ARRAY_APPEND(tables_to_plan, current_table);
        END IF;
    END FOR;

    -- Pre-compute plan count before using in VALUES clause (ARRAY_SIZE not allowed in VALUES)
    n := ARRAY_SIZE(tables_to_plan);

    INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
    VALUES (:execution_id, 'PLANNER', 'INFO',
            'Cache hits: ' || :skipped_count::VARCHAR ||
            ', to plan: ' || :n::VARCHAR);

    -- ── Dynamic token-budget batching ─────────────────────────────────────────
    i               := 0;
    batch_start_idx := 0;
    batch_token_count := base_overhead;
    batch_tables_list := '';

    WHILE (i <= n) DO

        IF (i < n) THEN
            current_table     := tables_to_plan[i]::VARCHAR;
            schema_info       := (CALL AGENT_FRAMEWORK.DISCOVER_SCHEMA(:current_table));
            current_schema_fp := MD5(schema_info::VARCHAR);

            SELECT AGENT_FRAMEWORK.DIRECTIVES_FOR_TABLE(
                SPLIT_PART(:current_table, '.', -1), 'SILVER'
            ) INTO :directives_context;

            SELECT LISTAGG(
                source_column || ' -> ' || SPLIT_PART(target_table, '.', -1) || '.' || target_column ||
                ' (' || relationship_type || ', ' || ROUND(confidence * 100)::VARCHAR || '% confidence)', '\n'
            ) INTO :relationship_context
            FROM AGENT_FRAMEWORK.SCHEMA_RELATIONSHIPS
            WHERE execution_id = :execution_id
              AND UPPER(source_table) = UPPER(:current_table)
              AND confidence >= 0.7;

            SELECT COUNT(*) INTO :inbound_fk_count
            FROM AGENT_FRAMEWORK.SCHEMA_RELATIONSHIPS
            WHERE execution_id = :execution_id
              AND UPPER(target_table) = UPPER(:current_table)
              AND confidence >= 0.7;

            table_block :=
                '--- TABLE: ' || SPLIT_PART(current_table, '.', -1) || ' ---
Schema: ' || schema_info::VARCHAR || '
Directives: ' || COALESCE(directives_context, 'None — apply general hygiene') || '
Outbound FKs: ' || COALESCE(relationship_context, 'None detected') || '
Inbound FK count: ' || inbound_fk_count::VARCHAR;

            this_table_tokens := (LENGTH(table_block) / 4) + 50;
        END IF;

        fire_batch := (i = n)
            OR (i > batch_start_idx AND batch_token_count + this_table_tokens > token_budget);

        IF (fire_batch AND i > batch_start_idx) THEN
            batch_prompt := '
You are the PLANNER agent in an agentic data transformation workflow.

PIPELINE CONTEXT:
' || COALESCE(pipeline_context, 'Not configured — apply general best practices') || '

SCHEMA CONTRACTS (structural rules you must follow):
' || COALESCE(contracts_context, 'None configured') || '

PAST LEARNINGS:
' || COALESCE(existing_learnings, 'No prior learnings') || '

TASK: Analyze each Bronze table below and determine its Silver transformation strategy.

TABLES TO PLAN:
' || batch_tables_list || '

AVAILABLE STRATEGIES:
1. flatten_and_type  - Expand VARIANT fields, apply proper types
2. deduplicate       - Remove CDC duplicates, keep latest per natural key (immutable facts)
3. scd_type2         - Track full change history with effective_from/effective_to/is_current (master dimensions)
4. aggregate         - Pre-aggregate for analytical performance
5. normalize         - Split nested arrays into separate tables

STRATEGY RULES:
- inbound_fk_count >= 3 AND master entity (CUSTOMERS, ACCOUNTS, BRANCHES, EMPLOYEES, PRODUCTS, PORTFOLIOS, LOANS, CARDS) -> scd_type2
- inbound_fk_count < 3 OR transactional (TRANSACTIONS, PAYMENTS, AUTHORIZATIONS, FLAGS, ALERTS, EVENTS, TRANSFERS, DETAILS) -> deduplicate
- VARIANT columns -> flatten_and_type  |  Junction tables -> deduplicate

OUTPUT FORMAT: JSON object keyed by UPPER_SNAKE_CASE table name only. No markdown, no text outside JSON.
{
  "TABLE_NAME": {
    "source_table": "...", "target_table": "SILVER.<name>", "strategy": "<strategy>",
    "detected_patterns": {"has_nested_variant": false, "has_null_issues": false, "needs_type_casting": true, "has_duplicates": true, "has_cdc_columns": true},
    "transformations": [{"column": "...", "action": "...", "reason": "..."}],
    "primary_key_columns": ["..."], "priority": 3, "confidence": 0.9, "reasoning": "Brief explanation"
  }
}';

            SELECT SNOWFLAKE.CORTEX.COMPLETE(:active_model, :batch_prompt) INTO :llm_response;

            obj_start := POSITION('{' IN llm_response);
            obj_end   := 0;
            depth     := 0;
            pos       := obj_start;
            rlen      := LENGTH(llm_response);

            WHILE (pos <= rlen AND (obj_end = 0 OR depth > 0)) DO
                IF     (SUBSTR(llm_response, pos, 1) = '{') THEN depth := depth + 1;
                ELSEIF (SUBSTR(llm_response, pos, 1) = '}') THEN
                    depth := depth - 1;
                    IF (depth = 0) THEN obj_end := pos; END IF;
                END IF;
                pos := pos + 1;
            END WHILE;

            BEGIN
                IF (obj_start > 0 AND obj_end > obj_start) THEN
                    parsed_batch := PARSE_JSON(SUBSTR(llm_response, obj_start, obj_end - obj_start + 1));
                ELSE
                    parsed_batch := NULL;
                END IF;
            EXCEPTION WHEN OTHER THEN
                parsed_batch := NULL;
            END;

            j := batch_start_idx;
            WHILE (j < i) DO
                extract_table := tables_to_plan[j]::VARCHAR;
                extract_key   := UPPER(SPLIT_PART(extract_table, '.', -1));
                schema_info_ext := (CALL AGENT_FRAMEWORK.DISCOVER_SCHEMA(:extract_table));
                extract_fp    := MD5(schema_info_ext::VARCHAR);

                BEGIN
                    IF (parsed_batch IS NOT NULL AND GET(:parsed_batch, :extract_key) IS NOT NULL) THEN
                        parsed_plan := GET(:parsed_batch, :extract_key);
                    ELSE
                        parsed_plan := OBJECT_CONSTRUCT(
                            'source_table', :extract_table, 'target_table', 'SILVER.' || :extract_key,
                            'strategy', 'deduplicate', 'confidence', 0.4,
                            'reasoning', 'Default: key not found in batch for ' || :extract_key
                        );
                    END IF;
                EXCEPTION WHEN OTHER THEN
                    parsed_plan := OBJECT_CONSTRUCT(
                        'source_table', :extract_table, 'target_table', 'SILVER.' || :extract_key,
                        'strategy', 'deduplicate', 'confidence', 0.3, 'reasoning', 'Exception'
                    );
                END;

                INSERT INTO AGENT_FRAMEWORK.PLANNER_DECISIONS (
                    execution_id, source_table, target_schema, transformation_strategy,
                    detected_patterns, recommended_actions, priority, llm_reasoning,
                    confidence_score, model_used, schema_fingerprint
                )
                SELECT :execution_id, :extract_table, 'SILVER',
                       :parsed_plan:strategy::VARCHAR,
                       :parsed_plan:detected_patterns,
                       :parsed_plan:transformations,
                       COALESCE(:parsed_plan:priority::INTEGER, 3),
                       :parsed_plan:reasoning::VARCHAR,
                       COALESCE(:parsed_plan:confidence::FLOAT, 0.5),
                       :active_model, :extract_fp;

                LET log_msg VARCHAR := :extract_key || ' -> ' || COALESCE(:parsed_plan:strategy::VARCHAR, 'null');
                INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
                VALUES (:execution_id, 'PLANNER', 'OK', :log_msg);

                all_decisions := ARRAY_APPEND(all_decisions, parsed_plan);
                planned_count := planned_count + 1;
                j := j + 1;
            END WHILE;

            batch_tables_list := '';
            batch_token_count := base_overhead;
            batch_start_idx   := i;
            fire_batch        := FALSE;
        END IF;

        IF (i < n) THEN
            IF (LENGTH(batch_tables_list) = 0) THEN
                batch_tables_list := table_block;
            ELSE
                batch_tables_list := batch_tables_list || '\n\n' || table_block;
            END IF;
            batch_token_count := batch_token_count + this_table_tokens;
        END IF;

        i := i + 1;
    END WHILE;

    UPDATE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
    SET planner_output = OBJECT_CONSTRUCT(
            'decisions',      :all_decisions,
            'tables_planned', :planned_count,
            'tables_reused',  :skipped_count,
            'model_used',     :active_model,
            'completed_at',   CURRENT_TIMESTAMP()::VARCHAR
        ),
        planning_completed_at = CURRENT_TIMESTAMP(),
        current_phase         = 'PLANNER_COMPLETE'
    WHERE execution_id = :execution_id;

    INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
    VALUES (:execution_id, 'PLANNER', 'COMPLETE',
            'Planned ' || :planned_count::VARCHAR ||
            ' tables (' || :skipped_count::VARCHAR || ' cache hits)');

    RETURN OBJECT_CONSTRUCT(
        'execution_id',    execution_id,
        'status',          'PLANNED',
        'decisions_count', planned_count + skipped_count,
        'tables_planned',  planned_count,
        'tables_reused',   skipped_count,
        'model_used',      active_model,
        'next_phase',      'EXECUTOR'
    );
END;
$$;
