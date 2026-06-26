-- =============================================================================
-- 02_schema_contracts.sql
-- Schema Contracts: structural rules the LLM agents must follow when
-- generating Silver/Gold DDL. Editable via Streamlit Tab 2.
-- =============================================================================

USE DATABASE IDENTIFIER($TARGET_DB);

-- ---------------------------------------------------------------------------
-- SCHEMA_CONTRACTS
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS AGENT_FRAMEWORK.SCHEMA_CONTRACTS (
    contract_id         VARCHAR         DEFAULT UUID_STRING(),
    contract_scope      VARCHAR         NOT NULL,
    rule_category       VARCHAR         NOT NULL,
    rule_name           VARCHAR         NOT NULL,
    rule_value          VARCHAR         NOT NULL,
    description         TEXT,
    applies_to_layer    VARCHAR         DEFAULT 'BOTH',
    is_active           BOOLEAN         DEFAULT TRUE,
    created_by          VARCHAR         DEFAULT CURRENT_USER(),
    created_at          TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    updated_at          TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_contracts PRIMARY KEY (contract_id),
    CONSTRAINT uq_contract_rule UNIQUE (contract_scope, rule_category, rule_name)
);

-- ---------------------------------------------------------------------------
-- SEED_DEFAULT_CONTRACTS
-- Called by BOOTSTRAP when SCHEMA_CONTRACTS is empty.
-- Encodes sensible structural defaults for Silver/Gold.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.SEED_DEFAULT_CONTRACTS()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    -- MERGE on the unique key (scope + category + name) so this SP is safe to
    -- call multiple times without creating duplicates, and preserves any
    -- custom contracts the user has added with non-default rule_names.
    MERGE INTO AGENT_FRAMEWORK.SCHEMA_CONTRACTS AS target
    USING (
        SELECT column1 AS contract_scope,
               column2 AS rule_category,
               column3 AS rule_name,
               column4 AS rule_value,
               column5 AS description,
               column6 AS applies_to_layer
        FROM VALUES

            -- CDC columns (standard IS_DELETED pattern; no _SNOWFLAKE_* Openflow columns)
            ('global', 'cdc_columns',   'delete_flag',         'IS_DELETED',           'Boolean column indicating soft-deleted rows',                                   'SILVER'),
            ('global', 'cdc_columns',   'operation_column',    'OPERATION',             'DML operation indicator: INSERT/UPDATE/DELETE',                                 'SILVER'),

            -- Deduplication
            ('global', 'deduplication', 'strategy',            'keep_latest',           'Retain the most recent row per natural key',                                   'SILVER'),
            ('global', 'deduplication', 'tiebreak_column',     'UPDATED_AT',            'Use UPDATED_AT to determine the most recent row; fall back to CREATED_AT',     'SILVER'),

            -- Type conventions
            ('global', 'types',         'timestamp_type',      'TIMESTAMP_NTZ',         'All timestamp columns must use TIMESTAMP_NTZ (no timezone)',                   'BOTH'),
            ('global', 'types',         'string_max_length',   'VARCHAR(16777216)',      'Use max-length VARCHAR; avoid imposing arbitrary limits',                      'BOTH'),
            ('global', 'types',         'boolean_handling',    'cast_to_boolean',        'Cast 0/1 and T/F strings to BOOLEAN where appropriate',                        'BOTH'),
            ('global', 'types',         'monetary_precision',  'NUMBER(18,4)',           'All AMOUNT, BALANCE, RATE, FEE, PRINCIPAL, INTEREST columns cast to NUMBER(18,4)', 'SILVER'),

            -- NULL handling
            ('global', 'nulls',         'empty_string_policy', 'preserve_empty',        'Do NOT convert empty strings to NULL; preserve source value',                  'SILVER'),
            ('global', 'nulls',         'required_fields',     'COALESCE_with_default', 'Use COALESCE for business-critical fields; document the default',              'BOTH'),

            -- Naming conventions
            ('global', 'naming',        'column_case',         'UPPER_SNAKE_CASE',      'All column names must be UPPER_SNAKE_CASE',                                    'BOTH'),
            ('global', 'naming',        'silver_prefix',       'none',                  'Silver tables match Bronze table name without prefix',                          'SILVER'),
            ('global', 'naming',        'gold_prefix',         'none',                  'Gold tables use descriptive names reflecting business intent',                  'GOLD'),

            -- SCD Type 2
            ('global', 'scd',           'scd2_column_names',   'EFFECTIVE_FROM TIMESTAMP_NTZ, EFFECTIVE_TO TIMESTAMP_NTZ DEFAULT NULL, IS_CURRENT BOOLEAN DEFAULT TRUE',
                                                                                         'SCD Type 2 tables must use these exact column names and types',                'SILVER'),

            -- Security
            ('global', 'security',      'pci_column_masking',  'MASK_OR_EXCLUDE',       'Columns named CARD_NUMBER, CVV, PAN, FULL_ACCOUNT_NUMBER must be masked to last 4 digits or excluded. Never pass raw values through.', 'BOTH'),

            -- Clustering
            ('global', 'clustering',    'silver_cluster_key',  'ingest_date',           'Cluster Silver tables on ingest date for time-range pruning',                  'SILVER'),

            -- Data preservation
            ('global', 'preservation',  'drop_source_columns', 'FALSE',                 'Do not drop source columns; only add/transform',                               'SILVER'),
            ('global', 'preservation',  'row_count_tolerance', '0.01',                  'Silver row count must be within 1% of Bronze (dedup adjusted)',                'SILVER')

    ) AS src ON (
        target.contract_scope  = src.contract_scope  AND
        target.rule_category   = src.rule_category   AND
        target.rule_name       = src.rule_name
    )
    WHEN MATCHED THEN UPDATE SET
        rule_value       = src.rule_value,
        description      = src.description,
        applies_to_layer = src.applies_to_layer,
        updated_at       = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
        (contract_scope, rule_category, rule_name, rule_value, description, applies_to_layer)
    VALUES
        (src.contract_scope, src.rule_category, src.rule_name, src.rule_value, src.description, src.applies_to_layer);

    RETURN 'Seeded ' || (SELECT COUNT(*) FROM AGENT_FRAMEWORK.SCHEMA_CONTRACTS WHERE is_active = TRUE)::VARCHAR || ' contracts';
END;
$$;

-- ---------------------------------------------------------------------------
-- CONTRACTS_AS_PROMPT_CONTEXT
-- Returns the active contracts formatted for LLM prompt injection.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION AGENT_FRAMEWORK.CONTRACTS_AS_PROMPT_CONTEXT(target_layer VARCHAR)
RETURNS TEXT
LANGUAGE SQL
AS
$$
    SELECT LISTAGG(
        '- [' || rule_category || '/' || rule_name || '] ' || rule_value || ': ' || COALESCE(description, ''),
        '\n'
    )
    FROM AGENT_FRAMEWORK.SCHEMA_CONTRACTS
    WHERE is_active = TRUE
      AND (applies_to_layer = UPPER(target_layer) OR applies_to_layer = 'BOTH')
    ORDER BY rule_category, rule_name
$$;
