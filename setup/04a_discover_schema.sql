-- =============================================================================
-- 04a_discover_schema.sql
-- DISCOVER_SCHEMA: Inspects a table's columns via INFORMATION_SCHEMA for LLM context.
-- =============================================================================

USE DATABASE IDENTIFIER($TARGET_DB);

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.DISCOVER_SCHEMA(table_fqn VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    db_part     VARCHAR;
    schema_part VARCHAR;
    table_part  VARCHAR;
    col_array   VARIANT;
    row_est     INTEGER;
    schema_info VARIANT;
BEGIN
    db_part     := SPLIT_PART(table_fqn, '.', 1);
    schema_part := SPLIT_PART(table_fqn, '.', 2);
    table_part  := SPLIT_PART(table_fqn, '.', 3);

    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
        'name',     column_name,
        'type',     data_type,
        'nullable', is_nullable,
        'position', ordinal_position
    )) INTO :col_array
    FROM information_schema.columns
    WHERE table_catalog = UPPER(:db_part)
      AND table_schema   = UPPER(:schema_part)
      AND table_name     = UPPER(:table_part);

    SELECT row_count INTO :row_est
    FROM information_schema.tables
    WHERE table_catalog = UPPER(:db_part)
      AND table_schema   = UPPER(:schema_part)
      AND table_name     = UPPER(:table_part)
    LIMIT 1;

    schema_info := OBJECT_CONSTRUCT(
        'table',        table_fqn,
        'columns',      col_array,
        'row_estimate', row_est
    );
    RETURN schema_info;
END;
$$;
