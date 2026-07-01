-- =============================================================================
-- 10_cortex_search.sql  [v3 NEW]
-- ATS Knowledge Search: indexes WORKFLOW_LEARNINGS, PLANNER_DECISIONS, and
-- SCHEMA_RELATIONSHIPS into a Cortex Search service so the Planner can
-- retrieve semantically similar prior decisions before calling the LLM.
--
-- Architecture:
--   ATS_KNOWLEDGE_CORPUS (VIEW) — UNION ALL over 3 knowledge tables
--   ATS_KNOWLEDGE_SEARCH (CORTEX SEARCH SERVICE) — indexes the view
--   SEARCH_ATS_KNOWLEDGE (FUNCTION) — called by Planner before each LLM batch
--
-- Cortex Sense bridge:
--   Short term: Planner calls SEARCH_ATS_KNOWLEDGE() to inject relevant
--   prior decisions into every prompt, reducing hallucination and retry loops
--   Long term: the Search Service + Semantic View (11_semantic_view.sql)
--   are the exact inputs Cortex Sense will consume when it goes GA
-- =============================================================================

USE DATABASE IDENTIFIER($TARGET_DB);

-- ---------------------------------------------------------------------------
-- ATS_KNOWLEDGE_CORPUS — backing view, UNION ALL over 3 knowledge tables
-- Cortex Search requires a single table/view source, not inline UNION ALL
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW AGENT_FRAMEWORK.ATS_KNOWLEDGE_CORPUS AS
  SELECT
      'learning'                                                    AS source_type,
      source_context,
      CASE WHEN confidence_score >= 0.85 THEN 'high'
           WHEN confidence_score >= 0.65 THEN 'medium'
           ELSE 'low' END                                           AS confidence_bucket,
      '[' || UPPER(learning_type) || '] ' || source_context || ': ' ||
      observation || ' - Recommendation: ' || recommendation       AS text_content
  FROM AGENT_FRAMEWORK.WORKFLOW_LEARNINGS
  WHERE is_active = TRUE AND confidence_score >= 0.5

  UNION ALL

  SELECT
      'planner_decision',
      SPLIT_PART(source_table, '.', -1),
      CASE WHEN confidence_score >= 0.85 THEN 'high'
           WHEN confidence_score >= 0.65 THEN 'medium'
           ELSE 'low' END,
      '[PLAN] ' || SPLIT_PART(source_table, '.', -1) ||
      ' (' || transformation_strategy || '): ' ||
      COALESCE(llm_reasoning, '') || ' | PK: ' || COALESCE(pk_columns, 'unknown')
  FROM AGENT_FRAMEWORK.PLANNER_DECISIONS
  WHERE confidence_score >= 0.6

  UNION ALL

  SELECT
      'schema_relationship',
      source_table,
      CASE WHEN confidence >= 0.85 THEN 'high'
           WHEN confidence >= 0.65 THEN 'medium'
           ELSE 'low' END,
      '[FK] ' || SPLIT_PART(source_table, '.', -1) || '.' || source_column ||
      ' -> ' || SPLIT_PART(target_table, '.', -1) ||
      COALESCE('.' || target_column, '') ||
      ' (' || relationship_type || ', ' || ROUND(confidence * 100)::VARCHAR || '% confidence)'
  FROM AGENT_FRAMEWORK.SCHEMA_RELATIONSHIPS
  WHERE confidence >= 0.65;

-- ---------------------------------------------------------------------------
-- ATS_KNOWLEDGE_SEARCH — Cortex Search service over the corpus view
-- Auto-refreshes every hour as new runs add learnings and decisions
-- ---------------------------------------------------------------------------

-- IDENTIFIER($WAREHOUSE) is not supported in CREATE CORTEX SEARCH SERVICE DDL.
-- Use EXECUTE IMMEDIATE with string concatenation to inject the warehouse name.
EXECUTE IMMEDIATE
    'CREATE OR REPLACE CORTEX SEARCH SERVICE AGENT_FRAMEWORK.ATS_KNOWLEDGE_SEARCH'
    || ' ON text_content'
    || ' ATTRIBUTES source_type, source_context, confidence_bucket'
    || ' WAREHOUSE = ' || $WAREHOUSE
    || ' TARGET_LAG = ''1 hour'''
    || ' AS SELECT source_type, source_context, confidence_bucket, text_content'
    || ' FROM AGENT_FRAMEWORK.ATS_KNOWLEDGE_CORPUS';

-- ---------------------------------------------------------------------------
-- SEARCH_ATS_KNOWLEDGE — called by Planner before each LLM batch
-- Returns top-N prior decisions/learnings relevant to the given table list
-- Falls back gracefully if search service has no data yet
-- ---------------------------------------------------------------------------

-- NOTE: SEARCH_PREVIEW requires a constant 2nd argument, so this must be a
-- stored procedure (not a SQL UDF). The Planner calls it with CALL ... INTO.
CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.SEARCH_ATS_KNOWLEDGE(
    query       VARCHAR,
    max_results INTEGER
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json

def run(session, query: str, max_results: int) -> str:
    try:
        payload = json.dumps({"query": query, "limit": max_results})
        row = session.sql(
            "SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(?, ?) AS resp",
            params=["ATS_V3.AGENT_FRAMEWORK.ATS_KNOWLEDGE_SEARCH", payload]
        ).collect()[0]
        raw = row["RESP"]
        resp = json.loads(raw) if isinstance(raw, str) else raw
        results = resp.get("results", [])
        if not results:
            return "No prior knowledge found."
        texts = []
        for r in results:
            tc = r.get("TEXT_CONTENT") or r.get("text_content") or ""
            if tc:
                texts.append(tc)
        return "\n---\n".join(texts) if texts else "No prior knowledge found."
    except Exception as e:
        return f"Search unavailable: {str(e)}"
$$;
