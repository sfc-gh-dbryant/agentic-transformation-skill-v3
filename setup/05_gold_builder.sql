-- =============================================================================
-- 05_gold_builder.sql
-- Gold layer agentic executor, dry-run proposal SP, and DCM export SP.
-- GOLD_AGENTIC_EXECUTOR and BUILD_GOLD_FOR_NEW_TABLES are Python stored
-- procedures (matching ADF pattern) to avoid Snowflake scripting limitations.
-- =============================================================================

USE DATABASE IDENTIFIER($TARGET_DB);

-- ---------------------------------------------------------------------------
-- GOLD_AGENTIC_EXECUTOR (Python)
-- Executes a Gold DDL statement with up to 3 LLM self-correction retries.
-- Supports multi-statement DDL (CREATE TABLE + ALTER TABLE CLUSTER BY).
-- Updates TABLE_LINEAGE_MAP on success using source_silver_table.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.GOLD_AGENTIC_EXECUTOR(
    ddl_statement        VARCHAR,
    source_silver_table  VARCHAR DEFAULT NULL
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS $$
import re, json

def run(session, ddl_statement, source_silver_table=None):
    model_rows = session.sql(
        "SELECT primary_model FROM AGENT_FRAMEWORK.MODEL_CONFIG WHERE config_key = 'default' LIMIT 1"
    ).collect()
    active_model = model_rows[0][0] if model_rows else 'claude-3-7-sonnet'

    working_ddl = ddl_statement.replace('\u2264', '<=').replace('\u2265', '>=')

    if 'DROP ' in working_ddl.upper() or 'TRUNCATE ' in working_ddl.upper():
        return {'status': 'REJECTED', 'reason': 'DROP and TRUNCATE not permitted via Gold Builder'}

    max_retries = 3
    retry_count = 0
    last_error  = None

    while retry_count < max_retries:
        try:
            stmts = [s.strip() for s in working_ddl.split(';') if len(s.strip()) > 3]
            for stmt in stmts:
                session.sql(stmt).collect()

            match = re.search(r'TABLE\s+([\w\.]+)', working_ddl, re.IGNORECASE)
            extracted_table = match.group(1).strip() if match else ''
            gold_table_name = extracted_table.split('.')[-1]
            gold_schema     = extracted_table.split('.')[-2] if '.' in extracted_table else 'GOLD'

            silver_tbl = source_silver_table
            if not silver_tbl:
                src = re.search(r'FROM\s+(?:[\w]+\.)*?([\w]+)(?:\s|$|;)', working_ddl, re.IGNORECASE)
                silver_tbl = src.group(1) if src else None

            if silver_tbl:
                silver_tbl_safe = silver_tbl.replace("'", "''")
                session.sql(f"""
                    UPDATE AGENT_FRAMEWORK.TABLE_LINEAGE_MAP
                    SET gold_table        = '{gold_table_name}',
                        gold_schema       = '{gold_schema}',
                        gold_status       = 'COMPLETE',
                        last_refreshed_at = CURRENT_TIMESTAMP(),
                        updated_at        = CURRENT_TIMESTAMP()
                    WHERE UPPER(silver_table) = UPPER('{silver_tbl_safe}')
                """).collect()

            return {
                'status':    'EXECUTED',
                'gold_table': extracted_table,
                'attempts':  retry_count + 1,
                'model_used': active_model
            }

        except Exception as e:
            last_error  = str(e)[:500]
            retry_count += 1

            if retry_count < max_retries:
                fix_prompt = (
                    f"The following Snowflake DDL failed with error: {last_error}\n\n"
                    f"Fix the DDL. Rules:\n"
                    f"1. Use only columns that exist in the source Silver table.\n"
                    f"2. Use ASCII operators (<= not ≤, >= not ≥).\n"
                    f"3. CLUSTER BY must be a separate ALTER TABLE after the CREATE.\n"
                    f"4. Output raw SQL only — no markdown, no explanation.\n\n"
                    f"FAILED SQL:\n{working_ddl}"
                )
                fix_escaped = fix_prompt.replace("'", "''")
                fix_rows   = session.sql(
                    f"SELECT SNOWFLAKE.CORTEX.COMPLETE('{active_model}', '{fix_escaped}')"
                ).collect()
                fix_resp   = fix_rows[0][0] if fix_rows else ''
                working_ddl = fix_resp.strip().replace('```sql', '').replace('```', '').strip()
                ci = working_ddl.upper().find('CREATE')
                if ci > 0:
                    working_ddl = working_ddl[ci:]

    return {'status': 'FAILED', 'error': last_error, 'ddl': working_ddl, 'attempts': retry_count}
$$;


-- ---------------------------------------------------------------------------
-- BUILD_GOLD_FOR_NEW_TABLES (Python)
-- Scans GOLD_GAPS, queries INFORMATION_SCHEMA for real column lists,
-- generates Gold DDL via LLM with 3-retry self-correction loop.
-- dry_run=TRUE returns proposals without executing (Streamlit review mode).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.BUILD_GOLD_FOR_NEW_TABLES(
    dry_run    BOOLEAN DEFAULT TRUE,
    max_tables INTEGER DEFAULT 10
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS $$
import re, json

def get_silver_metadata(session, current_db: str, silver_schema: str, silver_table: str) -> tuple:
    # silver_schema may be 'DB.SCHEMA' (cross-db) or plain 'SCHEMA'
    parts = silver_schema.split('.')
    info_db     = parts[0] if len(parts) > 1 else current_db
    schema_only = parts[-1]
    col_rows = session.sql(f"""
        SELECT LISTAGG(COLUMN_NAME || ' (' || DATA_TYPE || ')', ', ')
            WITHIN GROUP (ORDER BY ORDINAL_POSITION)
        FROM {info_db}.INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = UPPER('{schema_only}')
          AND TABLE_NAME   = UPPER('{silver_table}')
    """).collect()
    columns_list = col_rows[0][0] if col_rows and col_rows[0][0] else 'unknown'

    dir_rows = session.sql(f"""
        SELECT instructions FROM AGENT_FRAMEWORK.TRANSFORMATION_DIRECTIVES
        WHERE is_active = TRUE
          AND ('{silver_table}' LIKE source_table_pattern OR source_table_pattern = '%')
          AND target_layer IN ('GOLD', 'BOTH')
        ORDER BY priority DESC LIMIT 5
    """).collect()
    directives_ctx = '\n'.join(r[0] for r in dir_rows) if dir_rows else ''
    return columns_list, directives_ctx

def build_gold_prompt(silver_fqn: str, columns_list: str, contracts_ctx: str,
                      directives_ctx: str, gold_name: str,
                      is_dt: bool, target_lag: str, active_wh: str) -> str:
    fallback_directive = 'Build a clean analytical view with derived metrics'
    base = (
        f"SILVER TABLE: {silver_fqn}\n"
        f"AVAILABLE COLUMNS (use ONLY these, never invent others):\n{columns_list}\n\n"
        f"SCHEMA CONTRACTS:\n{contracts_ctx or 'None'}\n\n"
        f"DIRECTIVES:\n{directives_ctx or fallback_directive}\n\n"
        f"REQUIREMENTS:\n"
        f"1. Never use SELECT * — explicitly list every column by name.\n"
        f"2. Include at least 3 derived columns (DATEDIFF, CASE WHEN, COALESCE, arithmetic).\n"
        f"3. Use ONLY columns from AVAILABLE COLUMNS above — never reference others.\n"
        f"4. Use ASCII operators: <= not ≤, >= not ≥.\n"
        f"5. Gold table name: {gold_name}\n"
    )
    if is_dt:
        return (
            f"You are a Snowflake SQL expert building Gold analytical Dynamic Tables.\n\n{base}"
            f"6. CLUSTER BY goes inside the CREATE statement before AS, not in a separate ALTER.\n"
            f"7. Do NOT end with a semicolon.\n\n"
            f"OUTPUT: A single raw Snowflake SQL statement — no markdown, no explanation.\n"
            f"CREATE OR REPLACE DYNAMIC TABLE {gold_name}\n"
            f"    TARGET_LAG = '{target_lag}'\n"
            f"    WAREHOUSE = {active_wh}\n"
            f"    CLUSTER BY (<best column>)\n"
            f"AS SELECT ... FROM {silver_fqn}"
        )
    return (
        f"You are a Snowflake SQL expert building Gold analytical tables.\n\n{base}"
        f"6. CLUSTER BY must be in a separate ALTER TABLE statement after the CREATE.\n\n"
        f"OUTPUT: Raw Snowflake SQL only — no markdown fences, no explanations.\n"
        f"Statement 1: CREATE OR REPLACE TABLE {gold_name} AS SELECT ... FROM {silver_fqn}\n"
        f"Statement 2: ALTER TABLE {gold_name} CLUSTER BY (<best column>)"
    )

def clean_ddl(raw: str) -> str:
    ddl = raw.strip().replace('```sql', '').replace('```', '').strip()
    ci = ddl.upper().find('CREATE')
    return ddl[ci:] if ci > 0 else ddl

def run(session, dry_run=True, max_tables=10):
    model_rows   = session.sql(
        "SELECT primary_model FROM AGENT_FRAMEWORK.MODEL_CONFIG WHERE config_key = 'default' LIMIT 1"
    ).collect()
    active_model = model_rows[0][0] if model_rows else 'claude-3-7-sonnet'
    current_db   = session.sql("SELECT CURRENT_DATABASE()").collect()[0][0]
    active_wh    = session.sql("SELECT CURRENT_WAREHOUSE()").collect()[0][0]

    ctx_rows      = session.sql(
        "SELECT COALESCE(pipeline_type,'CTAS'), COALESCE(target_lag,'1 hour') "
        "FROM AGENT_FRAMEWORK.PIPELINE_CONTEXT WHERE context_id = 1"
    ).collect()
    pipeline_type = ctx_rows[0][0] if ctx_rows else 'CTAS'
    target_lag    = ctx_rows[0][1] if ctx_rows else '1 hour'
    is_dt         = (pipeline_type == 'DYNAMIC_TABLE')

    contracts_ctx = (session.sql(
        "SELECT AGENT_FRAMEWORK.CONTRACTS_AS_PROMPT_CONTEXT('GOLD')"
    ).collect()[0][0] or '')

    gaps_rows = session.sql(f"""
        SELECT silver_table, silver_schema FROM AGENT_FRAMEWORK.GOLD_GAPS LIMIT {int(max_tables)}
    """).collect()
    if not gaps_rows:
        return {'status': 'ALL_COVERED', 'proposals': [], 'executed': 0}

    proposals = []
    executed  = 0

    for row in gaps_rows:
        silver_table  = row[0]
        silver_schema = row[1]
        # silver_schema may be 'DB.SCHEMA' — use as-is, don't prepend current_db
        silver_fqn    = f"{silver_schema}.{silver_table}"
        # derive Gold output schema from pipeline context output_schema
        ctx_schema_rows = session.sql(
            "SELECT COALESCE(NULLIF(output_schema,''),'GOLD') FROM AGENT_FRAMEWORK.PIPELINE_CONTEXT WHERE context_id=1"
        ).collect()
        output_schema = ctx_schema_rows[0][0] if ctx_schema_rows else 'GOLD'
        # replace trailing schema segment with GOLD (e.g. ATS_V3_TEST.SILVER -> ATS_V3_TEST.GOLD)
        parts = output_schema.split('.')
        gold_db     = parts[0] if len(parts) > 1 else current_db
        gold_schema_name = 'GOLD'
        gold_name   = f"{gold_db}.{gold_schema_name}.{silver_table}_ANALYTICS"

        columns_list, directives_ctx = get_silver_metadata(session, current_db, silver_schema, silver_table)

        prompt = build_gold_prompt(silver_fqn, columns_list, contracts_ctx,
                                   directives_ctx, gold_name, is_dt, target_lag, active_wh)
        prompt_escaped = prompt.replace("'", "''")
        llm_rows = session.sql(
            f"SELECT SNOWFLAKE.CORTEX.COMPLETE('{active_model}', '{prompt_escaped}')"
        ).collect()
        proposed_ddl = clean_ddl(llm_rows[0][0] if llm_rows else '')

        if dry_run:
            proposals.append({'silver_table': silver_fqn, 'proposed_ddl': proposed_ddl,
                               'executed': False, 'exec_result': None})
            continue

        max_retries = 3
        retry_count = 0
        last_error  = None
        success     = False
        working_ddl = proposed_ddl

        while retry_count < max_retries:
            try:
                stmts = [s.strip() for s in working_ddl.split(';') if len(s.strip()) > 3]
                for stmt in stmts:
                    session.sql(stmt).collect()

                match        = re.search(r'TABLE\s+([\w\.]+)', working_ddl, re.IGNORECASE)
                extracted    = match.group(1).strip() if match else gold_name
                gold_tbl_name = extracted.split('.')[-1]
                gold_schema   = extracted.split('.')[-2] if '.' in extracted else 'GOLD'

                session.sql(f"""
                    UPDATE AGENT_FRAMEWORK.TABLE_LINEAGE_MAP
                    SET gold_table = '{gold_tbl_name}', gold_schema = '{gold_schema}',
                        gold_status = 'COMPLETE', last_refreshed_at = CURRENT_TIMESTAMP(),
                        updated_at = CURRENT_TIMESTAMP()
                    WHERE UPPER(silver_table) = UPPER('{silver_table}')
                """).collect()

                proposals.append({'silver_table': silver_fqn, 'proposed_ddl': working_ddl,
                                   'executed': True,
                                   'exec_result': {'status': 'SUCCESS', 'gold_table': extracted,
                                                   'attempts': retry_count + 1}})
                executed += 1
                success = True
                break

            except Exception as e:
                last_error  = str(e)[:500]
                retry_count += 1
                if retry_count < max_retries:
                    fix_prompt = (
                        f"DDL failed: {last_error}\n"
                        f"Fix it. Use ONLY these columns: {columns_list}\n"
                        f"Use ASCII operators. CLUSTER BY in separate ALTER TABLE.\n"
                        f"FAILED SQL:\n{working_ddl}\nOUTPUT: Raw SQL only."
                    )
                    fix_escaped = fix_prompt.replace("'", "''")
                    fix_rows    = session.sql(
                        f"SELECT SNOWFLAKE.CORTEX.COMPLETE('{active_model}', '{fix_escaped}')"
                    ).collect()
                    working_ddl = clean_ddl(fix_rows[0][0] if fix_rows else '')

        if not success:
            proposals.append({'silver_table': silver_fqn, 'proposed_ddl': working_ddl,
                               'executed': False,
                               'exec_result': {'status': 'FAILED', 'error': last_error,
                                               'attempts': retry_count}})

    return {'dry_run': dry_run, 'proposals': proposals, 'executed': executed, 'model_used': active_model}
$$;


-- ---------------------------------------------------------------------------
-- EXPORT_DCM_PROJECT
-- Generates a DCM project (DEFINE statements + manifest) from all finalized
-- Gold tables in TABLE_LINEAGE_MAP. Writes files to the specified stage path.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.EXPORT_DCM_PROJECT(output_stage VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    gold_tables_ddl     VARCHAR DEFAULT '';
    access_grants_sql   VARCHAR DEFAULT '';
    manifest_yaml       VARCHAR;
    table_count         INTEGER DEFAULT 0;
    current_db          VARCHAR;
    raw_ddl             VARCHAR;
    table_fqn           VARCHAR;
    dcm_cursor CURSOR FOR
        SELECT DISTINCT tlm.gold_schema AS gs, tlm.gold_table AS gt, tlm.bronze_database AS bd
        FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP tlm
        WHERE tlm.gold_table IS NOT NULL
          AND tlm.gold_status = 'COMPLETE'
        ORDER BY tlm.gold_table;
BEGIN
    SELECT CURRENT_DATABASE() INTO :current_db;

    OPEN dcm_cursor;
    FOR record IN dcm_cursor DO
        table_fqn := record.bd || '.' || record.gs || '.' || record.gt;
        SELECT GET_DDL('TABLE', :table_fqn) INTO :raw_ddl;

        gold_tables_ddl := gold_tables_ddl ||
            '-- Source Silver: see TABLE_LINEAGE_MAP\n' ||
            REPLACE(raw_ddl, 'CREATE OR REPLACE TABLE', 'DEFINE TABLE') ||
            '\n\n';

        table_count := table_count + 1;
    END FOR;

    access_grants_sql := '-- Add GRANT statements as needed\n-- Example:\n-- GRANT SELECT ON TABLE ' ||
                         current_db || '.GOLD.<table_name> TO ROLE <consumer_role>;\n';

    manifest_yaml := 'manifest_version: 1\n' ||
                     'type: DCM_PROJECT\n' ||
                     'include_definitions:\n' ||
                     '  - definitions/.*\n' ||
                     '# Generated by AGENT_FRAMEWORK.EXPORT_DCM_PROJECT\n' ||
                     '# Exported: ' || CURRENT_TIMESTAMP()::VARCHAR || '\n' ||
                     '# Gold tables: ' || table_count::VARCHAR || '\n' ||
                     '# Source database: ' || current_db || '\n';

    EXECUTE IMMEDIATE
        'COPY INTO ' || output_stage || '/dcm_export/manifest.yml
         FROM (SELECT ''' || manifest_yaml || ''')
         FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = NONE COMPRESSION = NONE)
         OVERWRITE = TRUE
         SINGLE = TRUE';

    EXECUTE IMMEDIATE
        'COPY INTO ' || output_stage || '/dcm_export/definitions/gold_tables.sql
         FROM (SELECT ''' || REPLACE(gold_tables_ddl, '''', '''''') || ''')
         FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = NONE COMPRESSION = NONE)
         OVERWRITE = TRUE
         SINGLE = TRUE';

    EXECUTE IMMEDIATE
        'COPY INTO ' || output_stage || '/dcm_export/definitions/access.sql
         FROM (SELECT ''' || access_grants_sql || ''')
         FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = NONE COMPRESSION = NONE)
         OVERWRITE = TRUE
         SINGLE = TRUE';

    RETURN OBJECT_CONSTRUCT(
        'status',       'EXPORTED',
        'stage',        output_stage || '/dcm_export/',
        'table_count',  table_count,
        'files',        ARRAY_CONSTRUCT(
            output_stage || '/dcm_export/manifest.yml',
            output_stage || '/dcm_export/definitions/gold_tables.sql',
            output_stage || '/dcm_export/definitions/access.sql'
        ),
        'next_steps',   'Download from stage, commit to git, deploy with: snow dcm deploy <project_id> -c <connection>'
    );
END;
$$;
