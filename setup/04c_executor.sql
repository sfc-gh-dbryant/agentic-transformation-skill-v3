-- =============================================================================
-- 04c_executor.sql  [v3]
-- WORKFLOW_EXECUTOR: Generates Silver DDL via 3-retry self-correcting loop.
--
-- v3 changes (P0):
--   - Reads output_schema from PIPELINE_CONTEXT (default: AGENT_FRAMEWORK_OUTPUT)
--   - dry_run=TRUE by default: generates DDL, logs it, never executes
--   - overwrite_existing=FALSE by default: aborts if target table has rows
--   - Injects EXACT column list from INFORMATION_SCHEMA into prompt
--     to prevent LLM column name hallucination
-- =============================================================================

USE DATABASE IDENTIFIER($TARGET_DB);

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.WORKFLOW_EXECUTOR(execution_id VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    active_model        VARCHAR;
    active_warehouse    VARCHAR;
    pipeline_type       VARCHAR;
    target_lag          VARCHAR;
    output_schema       VARCHAR;
    is_dry_run          BOOLEAN;
    allow_overwrite     BOOLEAN;
    brownfield_mode     BOOLEAN;
    decisions_cursor CURSOR FOR
        SELECT decision_id, source_table, transformation_strategy, recommended_actions, llm_reasoning,
               ARRAY_TO_STRING(d.recommended_actions::ARRAY, '') AS pk_hint
        FROM   AGENT_FRAMEWORK.PLANNER_DECISIONS d
        WHERE  execution_id = ?
        ORDER BY priority ASC;

    generated_sql       VARCHAR;
    execution_prompt    VARCHAR;
    llm_response        VARCHAR;
    retry_count         INTEGER;
    max_retries         INTEGER DEFAULT 3;
    execution_succeeded BOOLEAN;
    last_error          VARCHAR;
    execution_results   ARRAY DEFAULT ARRAY_CONSTRUCT();
    success_count       INTEGER DEFAULT 0;
    fail_count          INTEGER DEFAULT 0;
    dry_run_count       INTEGER DEFAULT 0;
    cur_source_table    VARCHAR;
    cur_strategy        VARCHAR;
    cur_actions         VARCHAR;
    cur_reasoning       VARCHAR;
    cur_schema_info     VARIANT;
    contracts_context   TEXT;
    directives_context  TEXT;
    output_rules        TEXT;
    target_table_name   VARCHAR;
    target_fqn          VARCHAR;
    existing_row_count  INTEGER DEFAULT 0;
    col_list            VARCHAR;
    pk_columns          VARCHAR;   -- for deterministic fast path
    fast_path_used      BOOLEAN DEFAULT FALSE;
    conflict_fallback_schema VARCHAR;  -- redirect target for object-type conflicts
    effective_target_fqn     VARCHAR;  -- may differ from target_fqn on redirect
    obj_type                 VARCHAR;  -- TABLE_TYPE from INFORMATION_SCHEMA
    obj_is_dynamic           INTEGER DEFAULT 0; -- 1 if target is a DYNAMIC TABLE
    conflict_redirected      BOOLEAN DEFAULT FALSE;
BEGIN
    SELECT primary_model INTO :active_model
    FROM AGENT_FRAMEWORK.MODEL_CONFIG
    WHERE config_key = 'default' LIMIT 1;

    SELECT CURRENT_WAREHOUSE() INTO :active_warehouse;

    SELECT COALESCE(pipeline_type, 'CTAS'),
           COALESCE(target_lag, '1 hour'),
           COALESCE(NULLIF(output_schema, ''), 'AGENT_FRAMEWORK_OUTPUT'),
           COALESCE(dry_run, TRUE),
           COALESCE(overwrite_existing, FALSE),
           COALESCE(brownfield_mode, FALSE),
           conflict_fallback_schema
    INTO :pipeline_type, :target_lag, :output_schema, :is_dry_run, :allow_overwrite, :brownfield_mode, :conflict_fallback_schema
    FROM AGENT_FRAMEWORK.PIPELINE_CONTEXT
    WHERE context_id = 1;

    -- Resolve fallback schema: explicit config or auto-derive as output_schema_STAGING
    IF (:conflict_fallback_schema IS NULL OR :conflict_fallback_schema = '') THEN
        conflict_fallback_schema := :output_schema || '_STAGING';
    END IF;

    -- Safety: ensure both output schema and fallback schema exist
    EXECUTE IMMEDIATE 'CREATE SCHEMA IF NOT EXISTS ' || :output_schema;
    EXECUTE IMMEDIATE 'CREATE SCHEMA IF NOT EXISTS ' || :conflict_fallback_schema;

    UPDATE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
    SET status = 'EXECUTING', current_phase = 'EXECUTOR'
    WHERE execution_id = :execution_id;

    INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
    SELECT :execution_id, 'EXECUTOR', 'STARTED',
            'Executor started. model=' || :active_model ||
            ', pipeline_type=' || :pipeline_type ||
            ', output_schema=' || :output_schema ||
            ', dry_run=' || :is_dry_run::VARCHAR ||
            ', overwrite_existing=' || :allow_overwrite::VARCHAR ||
            ', brownfield_mode=' || :brownfield_mode::VARCHAR ||
            CASE WHEN :pipeline_type = 'DYNAMIC_TABLE'
                 THEN ', target_lag=' || :target_lag ELSE '' END;

    contracts_context := AGENT_FRAMEWORK.CONTRACTS_AS_PROMPT_CONTEXT('SILVER');

    -- Build output rules once — parameterized by output_schema
    IF (pipeline_type = 'DYNAMIC_TABLE') THEN
        output_rules := '
OUTPUT RULES (CRITICAL):
- Output EXACTLY ONE SQL statement.
- No markdown, no code fences, no backticks, no explanation.
- Start directly with CREATE OR REPLACE DYNAMIC TABLE.
- Target schema is ' || :output_schema || '. Use:
  CREATE OR REPLACE DYNAMIC TABLE ' || :output_schema || '.<name>
      TARGET_LAG = ''' || :target_lag || '''
      WAREHOUSE = ' || :active_warehouse || '
  AS
  <SELECT ...>
- NO semicolons anywhere in the output (not even at the end).
- NO ALTER TABLE, no separate CLUSTER BY, no COMMENT ON.
- ONLY use column names from the EXACT COLUMN LIST above. Do NOT invent column names.';
    ELSE
        output_rules := '
OUTPUT RULES (CRITICAL):
- Output EXACTLY ONE SQL statement.
- No markdown, no code fences, no backticks, no explanation.
- Start directly with CREATE OR REPLACE TABLE.
- Target schema is ' || :output_schema || ':
  CREATE OR REPLACE TABLE ' || :output_schema || '.<name> AS SELECT ...
- NO semicolons anywhere in the output (not even at the end).
- NO ALTER TABLE, no CLUSTER BY as a separate statement, no COMMENT ON.
- The output must be a single CREATE OR REPLACE TABLE ... AS SELECT statement and nothing else.
- ONLY use column names from the EXACT COLUMN LIST above. Do NOT invent column names.';
    END IF;

    OPEN decisions_cursor USING (execution_id);
    FOR record IN decisions_cursor DO
        cur_source_table := record.source_table;
        cur_strategy     := record.transformation_strategy;
        cur_actions      := record.recommended_actions::VARCHAR;
        cur_reasoning    := record.llm_reasoning;
        cur_schema_info  := (CALL AGENT_FRAMEWORK.DISCOVER_SCHEMA(:cur_source_table));

        -- [P0-3] Fetch EXACT column list from source database's INFORMATION_SCHEMA
        -- Uses EXECUTE IMMEDIATE to cross-database query when source is in a different DB
        BEGIN
            LET col_sql VARCHAR := 'SELECT LISTAGG(column_name, '', '') WITHIN GROUP (ORDER BY ordinal_position) FROM ' ||
                SPLIT_PART(:cur_source_table, '.', 1) || '.INFORMATION_SCHEMA.COLUMNS WHERE ' ||
                'UPPER(table_schema) = UPPER(''' || SPLIT_PART(:cur_source_table, '.', -2) || ''') AND ' ||
                'UPPER(table_name)   = UPPER(''' || SPLIT_PART(:cur_source_table, '.', -1) || ''')';
            LET col_rs  RESULTSET := (EXECUTE IMMEDIATE :col_sql);
            LET col_cur CURSOR FOR col_rs;
            OPEN col_cur;
            FETCH col_cur INTO col_list;
            CLOSE col_cur;
        EXCEPTION WHEN OTHER THEN
            col_list := NULL;
        END;

        IF (col_list IS NULL OR LENGTH(col_list) = 0) THEN
            col_list := '(column list unavailable — verify source table exists)';
        END IF;

        SELECT AGENT_FRAMEWORK.DIRECTIVES_FOR_TABLE(
            SPLIT_PART(:cur_source_table, '.', -1), 'SILVER'
        ) INTO :directives_context;

        -- Derive target FQN for safety checks
        target_table_name := SPLIT_PART(:cur_source_table, '.', -1);
        target_fqn        := :output_schema || '.' || :target_table_name;

        -- [P0-0] Object-type conflict check: redirect if target is a VIEW,
        --        DYNAMIC TABLE, or an empty regular table owned by another pipeline.
        --        Redirected tables are written to conflict_fallback_schema.
        conflict_redirected := FALSE;
        obj_type            := 'NOT_FOUND';
        obj_is_dynamic      := 0;

        BEGIN
            LET ot_rs RESULTSET := (EXECUTE IMMEDIATE
                'SELECT COALESCE(MAX(TABLE_TYPE),''NOT_FOUND'') FROM INFORMATION_SCHEMA.TABLES ' ||
                'WHERE UPPER(TABLE_SCHEMA) = UPPER(SPLIT_PART(''' || :output_schema || ''',''.'',-1)) ' ||
                'AND   UPPER(TABLE_NAME)   = UPPER(''' || :target_table_name || ''')');
            LET ot_cur CURSOR FOR ot_rs;
            OPEN ot_cur; FETCH ot_cur INTO obj_type; CLOSE ot_cur;
        EXCEPTION WHEN OTHER THEN
            obj_type := 'NOT_FOUND';
        END;

        IF (obj_type = 'VIEW') THEN
            -- Target is a VIEW — always redirect
            conflict_redirected := TRUE;
        ELSEIF (obj_type NOT IN ('NOT_FOUND')) THEN
            -- Target exists as a table — check if it is a Dynamic Table
            BEGIN
                LET dt_rs RESULTSET := (EXECUTE IMMEDIATE
                    'SELECT COUNT(*) FROM INFORMATION_SCHEMA.DYNAMIC_TABLES ' ||
                    'WHERE UPPER(TABLE_SCHEMA) = UPPER(SPLIT_PART(''' || :output_schema || ''',''.'',-1)) ' ||
                    'AND   UPPER(TABLE_NAME)   = UPPER(''' || :target_table_name || ''')');
                LET dt_cur CURSOR FOR dt_rs;
                OPEN dt_cur; FETCH dt_cur INTO obj_is_dynamic; CLOSE dt_cur;
            EXCEPTION WHEN OTHER THEN
                obj_is_dynamic := 0;
            END;
            IF (obj_is_dynamic > 0) THEN
                -- Target is a DYNAMIC TABLE — always redirect
                conflict_redirected := TRUE;
            ELSEIF (existing_row_count = 0 AND NOT :allow_overwrite) THEN
                -- Target is a regular table with 0 rows — may belong to another pipeline
                conflict_redirected := TRUE;
            END IF;
        END IF;

        IF (conflict_redirected) THEN
            effective_target_fqn := :conflict_fallback_schema || '.' || :target_table_name;
            INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
            SELECT :execution_id, 'EXECUTOR', 'REDIRECTED',
                   :target_fqn || ' conflict (' ||
                   CASE WHEN obj_type = 'VIEW'   THEN 'VIEW'
                        WHEN obj_is_dynamic > 0  THEN 'DYNAMIC TABLE'
                        ELSE 'EMPTY TABLE — possible pipeline ownership'
                   END || ') → redirected to ' || :effective_target_fqn;
        ELSE
            effective_target_fqn := :target_fqn;
        END IF;

        -- [P0-1] Existence check: abort if target has rows and overwrite is disabled
        existing_row_count := 0;
        BEGIN
            LET chk_rs  RESULTSET := (EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || :target_fqn || ' LIMIT 1');
            LET chk_cur CURSOR FOR chk_rs;
            OPEN chk_cur;
            FETCH chk_cur INTO existing_row_count;
            CLOSE chk_cur;
        EXCEPTION WHEN OTHER THEN
            existing_row_count := 0; -- table does not exist yet, safe to proceed
        END;

        IF (existing_row_count > 0 AND NOT allow_overwrite) THEN
            IF (brownfield_mode) THEN
                -- Brownfield: skip existing table, mark as EXISTING (not a failure)
                UPDATE AGENT_FRAMEWORK.TABLE_LINEAGE_MAP
                SET silver_table  = :target_table_name,
                    silver_schema = :output_schema,
                    silver_status = 'EXISTING',
                    updated_at    = CURRENT_TIMESTAMP()
                WHERE bronze_table = SPLIT_PART(:cur_source_table, '.', -1);

                INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
                SELECT :execution_id, 'EXECUTOR', 'SKIPPED',
                       :target_fqn || ' skipped — brownfield_mode=TRUE, table exists with ' ||
                       :existing_row_count::VARCHAR || ' rows. Registered as EXISTING.';
                execution_results := ARRAY_APPEND(execution_results, OBJECT_CONSTRUCT(
                    'table',         :cur_source_table,
                    'target',        :target_fqn,
                    'success',       TRUE,
                    'skipped',       TRUE,
                    'reason',        'BROWNFIELD_EXISTING',
                    'existing_rows', :existing_row_count
                ));
            ELSE
                fail_count := fail_count + 1;
                INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
                SELECT :execution_id, 'EXECUTOR', 'ABORTED',
                       :target_fqn || ' already exists with ' || :existing_row_count::VARCHAR ||
                       ' rows. Set overwrite_existing=>TRUE in SET_PIPELINE_CONTEXT to allow overwrite, or use a different output_schema.';
                execution_results := ARRAY_APPEND(execution_results, OBJECT_CONSTRUCT(
                    'table',         :cur_source_table,
                    'target',        :target_fqn,
                    'success',       FALSE,
                    'aborted',       TRUE,
                    'reason',        'TARGET_EXISTS_NO_OVERWRITE',
                    'existing_rows', :existing_row_count
                ));
            END IF;
            CONTINUE;
        END IF;

        retry_count         := 0;
        execution_succeeded := FALSE;
        last_error          := NULL;
        fast_path_used      := FALSE;

        -- ── Deterministic fast path (no LLM call) ─────────────────────────────
        -- deduplicate: ROW_NUMBER dedup using pk_columns from Planner decision
        -- direct_select / passthrough: straight SELECT * with type hygiene
        -- Both are 100% deterministic and ~40-100x faster than LLM path
        BEGIN
            IF (cur_strategy IN ('deduplicate', 'direct_select', 'passthrough')) THEN
                -- Resolve pk_columns from recommended_actions JSON
                LET pk_sql VARCHAR :=
                    'SELECT LISTAGG(UPPER(a.value:column::VARCHAR), '', '') WITHIN GROUP (ORDER BY 1) ' ||
                    'FROM TABLE(FLATTEN(PARSE_JSON(' ||
                    '''' || REPLACE(cur_actions, '''', '''''') || '''' ||
                    '))) a WHERE a.value:action IN (''set_primary_key'',''deduplicate_on'',''primary_key'')';
                LET pk_rs  RESULTSET := (EXECUTE IMMEDIATE :pk_sql);
                LET pk_cur CURSOR FOR pk_rs;
                OPEN pk_cur;
                FETCH pk_cur INTO pk_columns;
                CLOSE pk_cur;

                -- Build deterministic DDL
                IF (cur_strategy IN ('direct_select', 'passthrough')) THEN
                    -- Pure pass-through: select all columns, apply basic type hygiene
                    generated_sql :=
                        'CREATE OR REPLACE TABLE ' || effective_target_fqn || ' AS ' ||
                        'SELECT ' || col_list || ' ' ||
                        'FROM ' || cur_source_table;
                    fast_path_used := TRUE;

                ELSEIF (cur_strategy = 'deduplicate' AND pk_columns IS NOT NULL AND LENGTH(pk_columns) > 0) THEN
                    -- ROW_NUMBER dedup: latest row per PK, filter soft-deletes
                    generated_sql :=
                        'CREATE OR REPLACE TABLE ' || effective_target_fqn || ' AS ' ||
                        'WITH ranked AS (' ||
                        '  SELECT ' || col_list || ',' ||
                        '    ROW_NUMBER() OVER (' ||
                        '      PARTITION BY ' || pk_columns ||
                        '      ORDER BY UPDATED_AT DESC NULLS LAST, CREATED_AT DESC NULLS LAST' ||
                        '    ) AS _ats_rn' ||
                        '  FROM ' || cur_source_table ||
                        '  WHERE COALESCE(IS_DELETED, FALSE) = FALSE' ||
                        ')' ||
                        'SELECT ' || col_list || ' FROM ranked WHERE _ats_rn = 1';
                    fast_path_used := TRUE;
                END IF;
            END IF;
        EXCEPTION WHEN OTHER THEN
            fast_path_used := FALSE; -- fall through to LLM on any error
        END;

        IF (fast_path_used) THEN
            INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
            SELECT :execution_id, 'EXECUTOR', 'FAST_PATH',
                   SPLIT_PART(:cur_source_table, '.', -1) || ' -> ' || :effective_target_fqn ||
                   ' (deterministic, no LLM, strategy=' || :cur_strategy || ')';
        END IF;

        -- LLM path: only runs when fast path not used OR fast path failed
        WHILE (retry_count < max_retries AND NOT execution_succeeded AND NOT fast_path_used) DO
            execution_prompt := '
You are a Snowflake SQL expert. Write a single CREATE OR REPLACE TABLE statement.

SOURCE TABLE: ' || cur_source_table || '
TRANSFORMATION STRATEGY: ' || cur_strategy || '

══ AUTHORITATIVE COLUMN LIST (from INFORMATION_SCHEMA) ══
These are the ONLY valid column names for this table. Every column in your SELECT must come from this list — exactly as written, including case:
    ' || REPLACE(col_list, ', ', chr(10) || '    ') || '

[HARD RULE] Do NOT use any column name not in the list above. Do NOT invent names.
[HARD RULE] Do NOT use TRY_TO_VARCHAR() - it does not exist in Snowflake. Use TO_VARCHAR(x) for any value-to-string conversion.
[HARD RULE] The SELECT list must only contain real column names or expressions over real column names.

PLANNED TRANSFORMATIONS: ' || cur_actions || '
REASONING: ' || cur_reasoning || '

SCHEMA CONTRACTS:
' || COALESCE(contracts_context, 'None') || '

DIRECTIVES:
' || COALESCE(directives_context, 'Apply general hygiene') || '

' || CASE WHEN retry_count > 0
    THEN 'YOUR PREVIOUS ATTEMPT FAILED: ' || COALESCE(last_error, 'unknown error') ||
         chr(10) || 'VALID COLUMNS ARE: ' || col_list ||
         chr(10) || 'Every column in your SELECT must be in that list. Fix the offending column name and try again.'
    ELSE '' END || output_rules;

            SELECT SNOWFLAKE.CORTEX.COMPLETE(:active_model, :execution_prompt) INTO :llm_response;

            BEGIN
                -- Strip markdown fences (LLMs often wrap output in ```sql ... ``` despite instructions)
                generated_sql := TRIM(llm_response);
                generated_sql := REGEXP_REPLACE(generated_sql, '^```(sql)?[\\s\\r\\n]*', '', 1, 1, 'si');
                generated_sql := REGEXP_REPLACE(generated_sql, '[\\s\\r\\n]*```[\\s\\r\\n]*$', '', 1, 1, 'si');
                -- Remove any remaining inline backtick fences
                generated_sql := REGEXP_REPLACE(generated_sql, '```(sql)?', '', 1, 0, 'si');
                generated_sql := TRIM(generated_sql);
                -- Strip trailing semicolons (Snowflake EXECUTE IMMEDIATE rejects them)
                generated_sql := TRIM(SPLIT_PART(generated_sql, ';', 1));

                -- [P0-2a] Pre-execution column validation
                -- Parse SELECT columns from generated DDL and cross-check against col_list
                -- Catches hallucinated names before they hit EXECUTE IMMEDIATE
                BEGIN
                    LET parsed_cols VARCHAR;
                    LET bad_col     VARCHAR := NULL;
                    LET validate_sql VARCHAR := 'SELECT c.value::VARCHAR AS col ' ||
                        'FROM TABLE(FLATTEN(STRTOK_SPLIT_TO_TABLE(''' ||
                        REPLACE(REPLACE(REPLACE(REPLACE(generated_sql,
                            chr(10), ' '), chr(13), ' '), '  ', ' '),
                            '''', '''''') || ''', '' ''))) c ' ||
                        'WHERE CONTAINS(UPPER('',' || REPLACE(col_list, ', ', ',') || ',''), '','' || UPPER(c.value) || '','' ) = FALSE ' ||
                        'AND UPPER(c.value) RLIKE ''^[A-Z_][A-Z0-9_]*$'' ' ||
                        'AND c.value NOT IN (''CREATE'',''OR'',''REPLACE'',''TABLE'',''AS'',''SELECT'',''FROM'',''WHERE'',''GROUP'',''BY'',''ORDER'',''DISTINCT'',''CASE'',''WHEN'',''THEN'',''ELSE'',''END'',''AND'',''NOT'',''NULL'',''IS'',''IN'',''ON'',''JOIN'',''LEFT'',''INNER'',''OUTER'',''COUNT'',''MAX'',''MIN'',''SUM'',''AVG'',''COALESCE'',''TRY_TO_VARCHAR'',''UPPER'',''LOWER'',''TRIM'',''CAST'',''CURRENT_TIMESTAMP'') ' ||
                        'LIMIT 1';
                    -- skip validation if col_list unavailable
                    IF (col_list NOT LIKE '%(column list unavailable%') THEN
                        BEGIN
                            LET val_rs  RESULTSET := (EXECUTE IMMEDIATE :validate_sql);
                            LET val_cur CURSOR FOR val_rs;
                            OPEN val_cur;
                            FETCH val_cur INTO bad_col;
                            CLOSE val_cur;
                        EXCEPTION WHEN OTHER THEN
                            bad_col := NULL; -- validation query failed, skip check
                        END;
                    END IF;
                    IF (bad_col IS NOT NULL) THEN
                        last_error  := 'Column validation failed: [' || bad_col || '] not found in source schema. Valid columns: ' || col_list;
                        retry_count := retry_count + 1;
                        INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
                        SELECT :execution_id, 'EXECUTOR', 'RETRY',
                               SPLIT_PART(:cur_source_table, '.', -1) || ' pre-exec validation failed (attempt ' || :retry_count::VARCHAR || '): ' || :last_error;
                        CONTINUE;
                    END IF;
                END;

                -- [P0-2] DRY RUN: log DDL without executing
                IF (is_dry_run) THEN
                    execution_succeeded := TRUE;
                    dry_run_count := dry_run_count + 1;
                    INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
                    SELECT :execution_id, 'EXECUTOR', 'DRY_RUN',
                           '[DRY RUN] ' || :effective_target_fqn ||
                           ' — DDL generated, NOT executed. Set dry_run=>FALSE to run.' ||
                           chr(10) || LEFT(:generated_sql, 2000);
                ELSE
                    EXECUTE IMMEDIATE :generated_sql;
                    execution_succeeded := TRUE;
                    success_count := success_count + 1;

                    UPDATE AGENT_FRAMEWORK.TABLE_LINEAGE_MAP
                    SET silver_table      = SPLIT_PART(TRIM(REGEXP_SUBSTR(:generated_sql, 'TABLE\\s+([\\w\\.]+)', 1, 1, 'ie', 1)), '.', -1),
                        silver_schema     = SPLIT_PART(:effective_target_fqn, '.', -2),
                        silver_status     = 'COMPLETE',
                        last_execution_id = :execution_id,
                        last_refreshed_at = CURRENT_TIMESTAMP(),
                        updated_at        = CURRENT_TIMESTAMP()
                    WHERE bronze_table = SPLIT_PART(:cur_source_table, '.', -1);

                    INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
                    SELECT :execution_id, 'EXECUTOR', 'OK',
                           SPLIT_PART(:cur_source_table, '.', -1) || ' → ' || :effective_target_fqn ||
                           ' built as ' || :pipeline_type ||
                           ' (retries=' || :retry_count::VARCHAR || ')' ||
                           CASE WHEN conflict_redirected THEN ' [REDIRECTED from ' || :target_fqn || ']' ELSE '' END;
                END IF;

            EXCEPTION WHEN OTHER THEN
                last_error  := SQLERRM;
                retry_count := retry_count + 1;
                INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
                SELECT :execution_id, 'EXECUTOR', 'RETRY',
                       SPLIT_PART(:cur_source_table, '.', -1) || ' attempt ' || :retry_count::VARCHAR ||
                       ' failed: ' || LEFT(:last_error, 300);
            END;
        END WHILE;

        -- Fast path execution block (runs when WHILE loop was skipped)
        IF (fast_path_used AND NOT execution_succeeded) THEN
            BEGIN
                IF (is_dry_run) THEN
                    execution_succeeded := TRUE;
                    dry_run_count := dry_run_count + 1;
                    INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
                    SELECT :execution_id, 'EXECUTOR', 'DRY_RUN',
                           '[DRY RUN / FAST PATH] ' || :effective_target_fqn ||
                           ' — deterministic DDL generated, NOT executed.' ||
                           chr(10) || LEFT(:generated_sql, 2000);
                ELSE
                    EXECUTE IMMEDIATE :generated_sql;
                    execution_succeeded := TRUE;
                    success_count := success_count + 1;
                    UPDATE AGENT_FRAMEWORK.TABLE_LINEAGE_MAP
                    SET silver_table      = :target_table_name,
                        silver_schema     = SPLIT_PART(:effective_target_fqn, '.', -2),
                        silver_status     = 'COMPLETE',
                        last_execution_id = :execution_id,
                        last_refreshed_at = CURRENT_TIMESTAMP(),
                        updated_at        = CURRENT_TIMESTAMP()
                    WHERE bronze_table = SPLIT_PART(:cur_source_table, '.', -1);
                    INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
                    SELECT :execution_id, 'EXECUTOR', 'OK',
                           SPLIT_PART(:cur_source_table, '.', -1) || ' → ' || :effective_target_fqn ||
                           ' built via fast path (strategy=' || :cur_strategy || ')' ||
                           CASE WHEN conflict_redirected THEN ' [REDIRECTED from ' || :target_fqn || ']' ELSE '' END;
                END IF;
            EXCEPTION WHEN OTHER THEN
                -- Fast path DDL failed — log and mark as failed (no retry for deterministic DDL)
                last_error  := SQLERRM;
                fail_count  := fail_count + 1;
                INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
                SELECT :execution_id, 'EXECUTOR', 'FAILED',
                       SPLIT_PART(:cur_source_table, '.', -1) || ' fast path FAILED: ' || LEFT(:last_error, 400);
            END;
        END IF;

        -- LLM path failure reporting
        IF (NOT execution_succeeded AND NOT fast_path_used) THEN
            fail_count := fail_count + 1;
            INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
            SELECT :execution_id, 'EXECUTOR', 'FAILED',
                   SPLIT_PART(:cur_source_table, '.', -1) || ' FAILED after ' ||
                   :max_retries::VARCHAR || ' retries. Last error: ' || LEFT(COALESCE(:last_error, 'unknown'), 400);
        END IF;

        execution_results := ARRAY_APPEND(execution_results, OBJECT_CONSTRUCT(
            'table',         cur_source_table,
            'target',        target_fqn,
            'pipeline_type', pipeline_type,
            'success',       execution_succeeded,
            'dry_run',       is_dry_run,
            'retries',       retry_count,
            'error',         LEFT(COALESCE(last_error, ''), 500)
        ));
    END FOR;

    UPDATE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
    SET executor_output = OBJECT_CONSTRUCT(
            'results',        :execution_results,
            'success_count',  :success_count,
            'dry_run_count',  :dry_run_count,
            'fail_count',     :fail_count,
            'pipeline_type',  :pipeline_type,
            'output_schema',  :output_schema,
            'dry_run',        :is_dry_run,
            'model_used',     :active_model,
            'completed_at',   CURRENT_TIMESTAMP()::VARCHAR
        ),
        execution_completed_at = CURRENT_TIMESTAMP(),
        current_phase = 'EXECUTOR_COMPLETE'
    WHERE execution_id = :execution_id;

    INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
    SELECT :execution_id, 'EXECUTOR', 'COMPLETE',
           CASE WHEN :is_dry_run
                THEN '[DRY RUN] Generated DDL for ' || :dry_run_count::VARCHAR ||
                     ' tables. Nothing written. Set dry_run=>FALSE in SET_PIPELINE_CONTEXT to execute.'
                ELSE 'Built ' || :success_count::VARCHAR || '/' ||
                     (:success_count + :fail_count)::VARCHAR ||
                     ' tables in ' || :output_schema || ' as ' || :pipeline_type ||
                     '. Failures: ' || :fail_count::VARCHAR
           END;

    RETURN OBJECT_CONSTRUCT(
        'execution_id',  execution_id,
        'status',        IFF(is_dry_run, 'DRY_RUN_COMPLETE', IFF(fail_count = 0, 'EXECUTED', 'PARTIAL')),
        'success_count', success_count,
        'dry_run_count', dry_run_count,
        'fail_count',    fail_count,
        'pipeline_type', pipeline_type,
        'output_schema', output_schema,
        'dry_run',       is_dry_run,
        'model_used',    active_model,
        'next_phase',    'VALIDATOR'
    );

EXCEPTION WHEN OTHER THEN
    LET executor_error VARCHAR := SQLERRM;
    INSERT INTO AGENT_FRAMEWORK.WORKFLOW_LOG (execution_id, phase, status, message)
    SELECT :execution_id, 'EXECUTOR', 'FATAL',
           'Unhandled exception after ' || :success_count::VARCHAR || ' successes: ' || LEFT(:executor_error, 400);
    UPDATE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
    SET executor_output = OBJECT_CONSTRUCT(
            'results',        :execution_results,
            'success_count',  :success_count,
            'dry_run_count',  :dry_run_count,
            'fail_count',     :fail_count + 1,
            'pipeline_type',  :pipeline_type,
            'output_schema',  :output_schema,
            'model_used',     :active_model,
            'error',          LEFT(:executor_error, 500),
            'completed_at',   CURRENT_TIMESTAMP()::VARCHAR
        ),
        execution_completed_at = CURRENT_TIMESTAMP(),
        current_phase = 'EXECUTOR_ERROR'
    WHERE execution_id = :execution_id;
    RETURN OBJECT_CONSTRUCT(
        'execution_id',  execution_id,
        'status',        'ERROR',
        'error',         LEFT(executor_error, 500),
        'success_count', success_count,
        'dry_run_count', dry_run_count,
        'fail_count',    fail_count + 1,
        'output_schema', output_schema,
        'dry_run',       is_dry_run
    );
END;
$$;
