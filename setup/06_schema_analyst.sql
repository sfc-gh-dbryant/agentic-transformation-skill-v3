-- =============================================================================
-- 06_schema_analyst.sql
-- SCHEMA_ANALYST phase: single LLM call across ALL table schemas to discover
-- FK and entity-reference relationships (including non-obvious name mismatches).
-- Runs BEFORE PLANNER so relationship context can be injected per-table.
--
-- v3 fix: rewritten as Python SP to:
--   - Dynamically query the correct cross-database INFORMATION_SCHEMA per table
--   - Use a domain-agnostic prompt (not hardcoded to financial services)
--   - Emit correct FQN (DB.SCHEMA.TABLE) in output, not hardcoded database name
-- =============================================================================
USE DATABASE IDENTIFIER($TARGET_DB);

-- ── 1. Relationship store ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS AGENT_FRAMEWORK.SCHEMA_RELATIONSHIPS (
    relationship_id      VARCHAR        DEFAULT UUID_STRING() PRIMARY KEY,
    execution_id         VARCHAR,
    source_table         VARCHAR,
    source_column        VARCHAR,
    target_table         VARCHAR,
    target_column        VARCHAR,
    relationship_type    VARCHAR,       -- FK | SOFT_FK | LOOKUP
    confidence           FLOAT,
    llm_reasoning        VARCHAR,
    discovery_method     VARCHAR        DEFAULT 'SCHEMA_ANALYST',
    created_at           TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP()
);

-- ── 2. New columns on WORKFLOW_EXECUTIONS ────────────────────────────────────
ALTER TABLE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
    ADD COLUMN IF NOT EXISTS schema_analyst_completed_at TIMESTAMP_NTZ;
ALTER TABLE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
    ADD COLUMN IF NOT EXISTS schema_analyst_output VARIANT;

-- ── 3. WORKFLOW_SCHEMA_ANALYST stored procedure ──────────────────────────────
CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.WORKFLOW_SCHEMA_ANALYST(execution_id VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json, re

def get_columns(session, fqn: str) -> list:
    parts = fqn.upper().split('.')
    if len(parts) != 3:
        return []
    db, schema, table = parts
    try:
        rows = session.sql(
            f"SELECT COLUMN_NAME, DATA_TYPE "
            f"FROM {db}.INFORMATION_SCHEMA.COLUMNS "
            f"WHERE UPPER(TABLE_SCHEMA)='{schema}' AND UPPER(TABLE_NAME)='{table}' "
            f"ORDER BY ORDINAL_POSITION"
        ).collect()
        return [f"{r['COLUMN_NAME']} ({r['DATA_TYPE']})" for r in rows]
    except Exception:
        return []

def extract_json_array(text: str) -> list:
    start = text.find('[')
    if start == -1:
        return []
    depth, end = 0, -1
    for i in range(start, len(text)):
        if text[i] == '[':
            depth += 1
        elif text[i] == ']':
            depth -= 1
            if depth == 0:
                end = i
                break
    if end == -1:
        return []
    try:
        return json.loads(text[start:end+1])
    except Exception:
        return []

def get_tables_requested(session, execution_id: str) -> list:
    row = session.sql(
        f"SELECT tables_requested FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS "
        f"WHERE execution_id='{execution_id}' LIMIT 1"
    ).collect()
    if not row:
        return []
    tables = row[0]['TABLES_REQUESTED'] or []
    if isinstance(tables, str):
        try:
            tables = json.loads(tables)
        except Exception:
            tables = []
    return [str(t).upper().strip() for t in tables]

def build_schema_blocks(session, tables: list) -> list:
    blocks = []
    for tbl in tables:
        cols = get_columns(session, tbl)
        if cols:
            blocks.append(f"TABLE: {tbl}\nCOLUMNS: {', '.join(cols)}")
    return blocks

def build_analyst_prompt(schema_blocks: list) -> str:
    all_schemas_text = "\n\n".join(schema_blocks)
    return f"""You are a SCHEMA ANALYST for a data warehouse.

Analyze the table schemas below and identify foreign key and entity-reference relationships between tables.

Look for patterns like:
- A column in one table whose name and type suggests it references the primary key of another table
- Shared dimension columns (e.g. PROVINCE, CATEGORY, STORE_NUMBER, BANNER appearing across multiple tables)
- Columns with _ID, _CODE, _KEY, _REF, _NUM suffixes that reference other tables

SCHEMAS:
{all_schemas_text}

OUTPUT RULES:
- JSON array only — no explanation, no markdown, no code fences
- Only include relationships with confidence >= 0.70
- source_table and target_table must use the EXACT fully-qualified name from the SCHEMAS section above
- relationship_type: FK (enforced key), SOFT_FK (logical but not enforced), LOOKUP (reference/dimension table)
- If no relationships are found, return an empty array: []

[
  {{
    "source_table": "<EXACT_FQN_FROM_SCHEMAS>",
    "source_column": "<COLUMN_NAME>",
    "target_table": "<EXACT_FQN_FROM_SCHEMAS>",
    "target_column": "<COLUMN_NAME>",
    "relationship_type": "FK|SOFT_FK|LOOKUP",
    "confidence": 0.0,
    "reasoning": "brief explanation"
  }}
]"""

def store_relationships(session, parsed_rels: list, execution_id: str) -> int:
    rel_count = 0
    for r in parsed_rels:
        src_tbl  = r.get('source_table', '')
        src_col  = r.get('source_column', '')
        tgt_tbl  = r.get('target_table', '')
        tgt_col  = r.get('target_column', '')
        rel_type = r.get('relationship_type', 'SOFT_FK')
        conf     = float(r.get('confidence', 0.8))
        reasoning = str(r.get('reasoning', ''))[:500]
        if not src_tbl or not src_col:
            continue
        try:
            session.sql(
                "INSERT INTO AGENT_FRAMEWORK.SCHEMA_RELATIONSHIPS "
                "(execution_id, source_table, source_column, target_table, target_column, "
                "relationship_type, confidence, llm_reasoning, discovery_method) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'SCHEMA_ANALYST')",
                params=[execution_id, src_tbl, src_col, tgt_tbl, tgt_col,
                        rel_type, conf, reasoning]
            ).collect()
            rel_count += 1
        except Exception:
            pass
    return rel_count

def run(session, execution_id: str) -> dict:
    active_model = session.sql(
        "SELECT primary_model FROM AGENT_FRAMEWORK.MODEL_CONFIG WHERE config_key='default' LIMIT 1"
    ).collect()[0]['PRIMARY_MODEL']

    session.sql(
        f"UPDATE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS "
        f"SET status='ANALYZING', current_phase='SCHEMA_ANALYST' "
        f"WHERE execution_id='{execution_id}'"
    ).collect()

    tables  = get_tables_requested(session, execution_id)
    blocks  = build_schema_blocks(session, tables)

    if not blocks:
        session.sql(
            f"UPDATE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS "
            f"SET schema_analyst_output=PARSE_JSON('{{\"relationships_found\":0}}'), "
            f"schema_analyst_completed_at=CURRENT_TIMESTAMP(), "
            f"current_phase='SCHEMA_ANALYST_COMPLETE' "
            f"WHERE execution_id='{execution_id}'"
        ).collect()
        return {"execution_id": execution_id, "status": "ANALYZED",
                "relationships_found": 0, "model_used": active_model}

    prompt = build_analyst_prompt(blocks)
    try:
        llm_response = session.sql(
            "SELECT SNOWFLAKE.CORTEX.COMPLETE(?, ?) AS resp",
            params=[active_model, prompt]
        ).collect()[0]['RESP'] or ''
    except Exception:
        llm_response = '[]'

    rel_count = store_relationships(session, extract_json_array(llm_response), execution_id)

    session.sql(
        f"UPDATE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS "
        f"SET schema_analyst_output=PARSE_JSON('{{\"relationships_found\":{rel_count}}}'), "
        f"schema_analyst_completed_at=CURRENT_TIMESTAMP(), "
        f"current_phase='SCHEMA_ANALYST_COMPLETE' "
        f"WHERE execution_id='{execution_id}'"
    ).collect()

    return {
        "execution_id":       execution_id,
        "status":             "ANALYZED",
        "relationships_found": rel_count,
        "model_used":         active_model,
        "tables_analyzed":    len(blocks),
        "next_phase":         "PLANNER"
    }
$$;