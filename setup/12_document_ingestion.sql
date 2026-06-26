-- =============================================================================
-- 12_document_ingestion.sql  [v3 NEW — B-01]
-- Document Ingestion: upload PDFs/text docs to a stage, extract text via
-- PARSE_DOCUMENT, chunk into ATS_KNOWLEDGE_CORPUS so the Planner's RAG
-- search automatically retrieves relevant domain context.
--
-- Architecture:
--   @AGENT_FRAMEWORK.DOCUMENT_STAGE        — internal stage for uploaded files
--   DOCUMENT_CONTEXT_ITEMS                 — backing table for doc chunks
--   ATS_KNOWLEDGE_CORPUS (updated view)    — adds DOCUMENT_CONTEXT_ITEMS
--   INGEST_DOCUMENT_FROM_STAGE             — stage path → chunk → insert
--   INGEST_DOCUMENT_TEXT                   — raw text → chunk → insert
--   LIST_DOCUMENTS()                       — show indexed docs + chunk counts
--   REMOVE_DOCUMENT(doc_name)              — delete all chunks for a doc
-- =============================================================================

USE DATABASE IDENTIFIER($TARGET_DB);

-- ---------------------------------------------------------------------------
-- Stage for uploaded documents
-- ---------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS AGENT_FRAMEWORK.DOCUMENT_STAGE
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Document uploads for ATS knowledge augmentation (B-01)';

-- ---------------------------------------------------------------------------
-- DOCUMENT_CONTEXT_ITEMS — backing table for document chunks
-- Separate from WORKFLOW_LEARNINGS so docs survive CLEAR_WORKFLOW_HISTORY
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS AGENT_FRAMEWORK.DOCUMENT_CONTEXT_ITEMS (
    item_id         INTEGER AUTOINCREMENT PRIMARY KEY,
    doc_name        VARCHAR(500)  NOT NULL,
    doc_type        VARCHAR(100)  NOT NULL DEFAULT 'general',
    chunk_index     INTEGER       NOT NULL,
    text_content    TEXT          NOT NULL,
    confidence_bucket VARCHAR(10) NOT NULL DEFAULT 'high',
    created_by      VARCHAR                DEFAULT CURRENT_USER(),
    created_at      TIMESTAMP_NTZ          DEFAULT CURRENT_TIMESTAMP()
);

-- ---------------------------------------------------------------------------
-- Update ATS_KNOWLEDGE_CORPUS to include document chunks
-- The Cortex Search service (ATS_KNOWLEDGE_SEARCH) indexes this view
-- and will automatically pick up documents on its next refresh (1 hour)
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
  WHERE confidence >= 0.65

  UNION ALL

  SELECT
      'document_context'             AS source_type,
      doc_name                       AS source_context,
      confidence_bucket,
      '[DOC:' || UPPER(doc_type) || '] ' || doc_name || ' | ' || text_content AS text_content
  FROM AGENT_FRAMEWORK.DOCUMENT_CONTEXT_ITEMS;

-- ---------------------------------------------------------------------------
-- INGEST_DOCUMENT_FROM_STAGE
-- Reads a file from @DOCUMENT_STAGE using PARSE_DOCUMENT, chunks the text,
-- and inserts into DOCUMENT_CONTEXT_ITEMS.
-- Replaces any existing chunks for the same doc_name.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.INGEST_DOCUMENT_FROM_STAGE(
    stage_file_path VARCHAR,
    doc_name        VARCHAR,
    doc_type        VARCHAR DEFAULT 'general'
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json, re

CHUNK_SIZE = 1500   # characters per chunk (overlapping not needed; search handles retrieval)
CHUNK_OVERLAP = 100

def chunk_text(text: str, chunk_size: int = CHUNK_SIZE, overlap: int = CHUNK_OVERLAP) -> list:
    paragraphs = [p.strip() for p in re.split(r'\n{2,}', text) if p.strip()]
    chunks = []
    current = ""
    for para in paragraphs:
        if len(current) + len(para) + 1 <= chunk_size:
            current = (current + "\n" + para).strip()
        else:
            if current:
                chunks.append(current)
            if len(para) <= chunk_size:
                current = para
            else:
                for i in range(0, len(para), chunk_size - overlap):
                    chunks.append(para[i:i + chunk_size])
                current = ""
    if current:
        chunks.append(current)
    return chunks

def run(session, stage_file_path: str, doc_name: str, doc_type: str = 'general') -> dict:
    stage_path = stage_file_path if stage_file_path.startswith('@') else f'@AGENT_FRAMEWORK.DOCUMENT_STAGE/{stage_file_path}'

    try:
        parse_result = session.sql(
            f"SELECT SNOWFLAKE.CORTEX.PARSE_DOCUMENT('{stage_path}', {{'mode': 'LAYOUT'}}) AS content"
        ).collect()[0]['CONTENT']
        parsed = json.loads(parse_result) if isinstance(parse_result, str) else parse_result
        raw_text = parsed.get('content', '') or ''
    except Exception as e:
        return {"status": "ERROR", "error": f"PARSE_DOCUMENT failed: {str(e)}"}

    if not raw_text.strip():
        return {"status": "ERROR", "error": "Extracted text is empty. Verify the file is readable."}

    chunks = chunk_text(raw_text)
    if not chunks:
        return {"status": "ERROR", "error": "No text chunks produced."}

    session.sql(
        "DELETE FROM AGENT_FRAMEWORK.DOCUMENT_CONTEXT_ITEMS WHERE UPPER(doc_name) = UPPER(?)",
        params=[doc_name]
    ).collect()

    for i, chunk in enumerate(chunks):
        session.sql(
            "INSERT INTO AGENT_FRAMEWORK.DOCUMENT_CONTEXT_ITEMS "
            "(doc_name, doc_type, chunk_index, text_content, confidence_bucket) "
            "VALUES (?, ?, ?, ?, 'high')",
            params=[doc_name, doc_type.lower(), i, chunk]
        ).collect()

    return {
        "status":      "SUCCESS",
        "doc_name":    doc_name,
        "doc_type":    doc_type,
        "chunks":      len(chunks),
        "chars":       len(raw_text),
        "stage_path":  stage_path
    }
$$;

-- ---------------------------------------------------------------------------
-- INGEST_DOCUMENT_TEXT
-- Accepts raw text content directly (used by Streamlit for .txt/.md uploads).
-- Replaces any existing chunks for the same doc_name.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.INGEST_DOCUMENT_TEXT(
    doc_name     VARCHAR,
    doc_type     VARCHAR,
    content_text TEXT
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import json, re

CHUNK_SIZE = 1500
CHUNK_OVERLAP = 100

def chunk_text(text: str, chunk_size: int = CHUNK_SIZE, overlap: int = CHUNK_OVERLAP) -> list:
    paragraphs = [p.strip() for p in re.split(r'\n{2,}', text) if p.strip()]
    chunks = []
    current = ""
    for para in paragraphs:
        if len(current) + len(para) + 1 <= chunk_size:
            current = (current + "\n" + para).strip()
        else:
            if current:
                chunks.append(current)
            if len(para) <= chunk_size:
                current = para
            else:
                for i in range(0, len(para), chunk_size - overlap):
                    chunks.append(para[i:i + chunk_size])
                current = ""
    if current:
        chunks.append(current)
    return chunks

def run(session, doc_name: str, doc_type: str, content_text: str) -> dict:
    if not content_text or not content_text.strip():
        return {"status": "ERROR", "error": "content_text is empty."}

    chunks = chunk_text(content_text)
    if not chunks:
        return {"status": "ERROR", "error": "No text chunks produced."}

    session.sql(
        "DELETE FROM AGENT_FRAMEWORK.DOCUMENT_CONTEXT_ITEMS WHERE UPPER(doc_name) = UPPER(?)",
        params=[doc_name]
    ).collect()

    for i, chunk in enumerate(chunks):
        session.sql(
            "INSERT INTO AGENT_FRAMEWORK.DOCUMENT_CONTEXT_ITEMS "
            "(doc_name, doc_type, chunk_index, text_content, confidence_bucket) "
            "VALUES (?, ?, ?, ?, 'high')",
            params=[doc_name, doc_type.lower(), i, chunk]
        ).collect()

    return {
        "status":   "SUCCESS",
        "doc_name": doc_name,
        "doc_type": doc_type,
        "chunks":   len(chunks),
        "chars":    len(content_text)
    }
$$;

-- ---------------------------------------------------------------------------
-- LIST_DOCUMENTS — return indexed documents as JSON array (Python SP)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.LIST_DOCUMENTS()
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
        "SELECT doc_name, doc_type, COUNT(*) AS chunk_count, "
        "SUM(LENGTH(text_content)) AS total_chars, "
        "MIN(created_by) AS created_by, MIN(created_at) AS created_at "
        "FROM AGENT_FRAMEWORK.DOCUMENT_CONTEXT_ITEMS "
        "GROUP BY doc_name, doc_type "
        "ORDER BY created_at DESC"
    ).collect()
    return json.dumps([{
        "doc_name":    r['DOC_NAME'],
        "doc_type":    r['DOC_TYPE'],
        "chunk_count": r['CHUNK_COUNT'],
        "total_chars": r['TOTAL_CHARS'],
        "created_by":  r['CREATED_BY'],
        "created_at":  str(r['CREATED_AT'])
    } for r in rows])
$$;

-- ---------------------------------------------------------------------------
-- REMOVE_DOCUMENT — delete all chunks for a named document
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.REMOVE_DOCUMENT(doc_name VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    existing_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO :existing_count
    FROM AGENT_FRAMEWORK.DOCUMENT_CONTEXT_ITEMS
    WHERE UPPER(doc_name) = UPPER(:doc_name);

    DELETE FROM AGENT_FRAMEWORK.DOCUMENT_CONTEXT_ITEMS
    WHERE UPPER(doc_name) = UPPER(:doc_name);

    RETURN OBJECT_CONSTRUCT(
        'status',         IFF(:existing_count > 0, 'REMOVED', 'NOT_FOUND'),
        'doc_name',       :doc_name,
        'chunks_deleted', :existing_count
    )::VARCHAR;
END;
$$;
