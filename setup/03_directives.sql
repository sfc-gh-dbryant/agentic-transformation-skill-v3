-- =============================================================================
-- 03_directives.sql
-- Transformation Directives: per-table business intent injected into LLM
-- prompts. The human-in-the-middle control layer. Editable via Tab 3.
-- Adapted from ADF scripts/13_transformation_directives.sql.
-- =============================================================================

USE DATABASE IDENTIFIER($TARGET_DB);

-- ---------------------------------------------------------------------------
-- TRANSFORMATION_DIRECTIVES
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS AGENT_FRAMEWORK.TRANSFORMATION_DIRECTIVES (
    directive_id            VARCHAR         DEFAULT UUID_STRING(),
    source_table_pattern    VARCHAR         NOT NULL,
    target_layer            VARCHAR         NOT NULL,
    use_case                VARCHAR         NOT NULL,
    instructions            TEXT            NOT NULL,
    priority                INTEGER         DEFAULT 5,
    is_active               BOOLEAN         DEFAULT TRUE,
    created_by              VARCHAR         DEFAULT CURRENT_USER(),
    created_at              TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    updated_at              TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_directives PRIMARY KEY (directive_id)
);

CREATE OR REPLACE VIEW AGENT_FRAMEWORK.ACTIVE_DIRECTIVES AS
SELECT *
FROM AGENT_FRAMEWORK.TRANSFORMATION_DIRECTIVES
WHERE is_active = TRUE
ORDER BY priority DESC, source_table_pattern;

-- ---------------------------------------------------------------------------
-- SEED_DEFAULT_DIRECTIVES
-- Called by BOOTSTRAP when TRANSFORMATION_DIRECTIVES is empty.
-- Generic defaults that work across most Bronze schemas. SA/customer replaces
-- these with table-specific directives as they understand their data better.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.SEED_DEFAULT_DIRECTIVES()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    -- Delete only the known default use_cases so custom directives are preserved.
    -- Safe to call multiple times without creating duplicates.
    DELETE FROM AGENT_FRAMEWORK.TRANSFORMATION_DIRECTIVES
    WHERE use_case IN (
        'general_hygiene', 'ddl_validation', 'null_handling', 'type_casting',
        'master_dimension_scd2', 'immutable_transaction_fact',
        'compliance_audit_trail', 'pci_card_data'
    );

    INSERT INTO AGENT_FRAMEWORK.TRANSFORMATION_DIRECTIVES
        (source_table_pattern, target_layer, use_case, instructions, priority)
    SELECT column1, column2, column3, column4, column5 FROM VALUES

        -- ── Generic defaults (apply to all tables) ────────────────────────────

        ('%', 'SILVER', 'ddl_validation',
         'Before generating final DDL:
- Verify all referenced source columns exist in the Bronze schema provided
- Do not CREATE OR REPLACE if table already exists with different column count — use ALTER instead
- Validate that the primary key / dedup key columns are NOT NULL in the output
- Ensure no column name collisions between original columns and derived columns
- Generated DDL must be syntactically valid Snowflake SQL',
         10),

        ('%', 'SILVER', 'null_handling',
         'NULL and empty string handling:
- Empty strings must remain as empty strings — do NOT convert to NULL
- Apply NULLIF only when the source system explicitly uses sentinel values like -1, 9999, or N/A
- For numeric columns, treat 0 as a valid value unless business context says otherwise
- Document any COALESCE defaults used in column comments',
         8),

        ('%', 'SILVER', 'type_casting',
         'Type casting rules:
- VARIANT/OBJECT columns: expand to flat columns using $column:field::TYPE notation
- Strings that look like ISO 8601 timestamps: cast to TIMESTAMP_NTZ
- Strings that look like booleans (true/false, T/F, 1/0, yes/no): cast to BOOLEAN
- Numeric strings: cast to NUMBER with appropriate precision
- Do not over-cast — if type is ambiguous, leave as VARCHAR and note it in reasoning',
         7),

        ('%', 'SILVER', 'general_hygiene',
         'Apply general Silver layer hygiene to all tables:
- Preserve ALL source columns — do not drop any column present in Bronze
- Apply proper type casting: infer and cast to BOOLEAN, TIMESTAMP_NTZ, NUMBER where evident
- Handle NULLs defensively: use COALESCE for required business fields, document the default used
- Deduplicate using the most recent row per natural key; use UPDATED_AT as tiebreaker, fall back to CREATED_AT
- All timestamp columns must use TIMESTAMP_NTZ
- Column names must be UPPER_SNAKE_CASE
- Filter out soft-deleted rows (IS_DELETED = TRUE) unless preserving full history is specified',
         3),

        -- ── Dedup key selection — prevents wrong column picked as PK ─────────

        ('%', 'SILVER', 'dedup_key_selection',
         'When selecting the dedup / primary key column for a table:
- PREFER columns ending in _KEY or _ID (e.g. ITEM_KEY, CALENDAR_KEY, CUSTOMER_ID) over date or timestamp columns
- NEVER use a date or timestamp column (e.g. DAY_DATE, CREATED_AT, UPDATED_AT) as the primary dedup key unless there is NO _KEY or _ID column in the table
- If multiple _ID or _KEY columns exist, prefer the one whose name most closely matches the table name (e.g. CALENDAR_KEY for a CALENDAR table)
- When in doubt, deduplicate on the column with the highest cardinality relative to total row count
- Use TRY_TO_VARCHAR() for any numeric-to-string conversion. Do NOT use TRY_CAST(x AS VARCHAR).',
         6),

        -- ── Master dimension tables — SCD Type 2 ──────────────────────────────
        -- These tables are referenced by many downstream fact tables and change
        -- over time. Full change history is required for point-in-time joins.

        ('CUSTOMERS', 'SILVER', 'master_dimension_scd2',
         'CUSTOMERS is a master dimension. Apply SCD Type 2:
- Primary key: CUSTOMER_ID
- Add EFFECTIVE_FROM TIMESTAMP_NTZ, EFFECTIVE_TO TIMESTAMP_NTZ DEFAULT NULL, IS_CURRENT BOOLEAN DEFAULT TRUE
- Order changes by UPDATED_AT within each CUSTOMER_ID partition
- Do NOT filter IS_DELETED rows — represent deletions as a final row with IS_CURRENT=FALSE and EFFECTIVE_TO set
- This table is referenced by TRANSACTIONS, LOANS, CARDS, ACCOUNTS — accurate point-in-time joins are critical',
         9),

        ('ACCOUNTS', 'SILVER', 'master_dimension_scd2',
         'ACCOUNTS is a master dimension. Apply SCD Type 2:
- Primary key: ACCOUNT_ID
- Add EFFECTIVE_FROM TIMESTAMP_NTZ, EFFECTIVE_TO TIMESTAMP_NTZ DEFAULT NULL, IS_CURRENT BOOLEAN DEFAULT TRUE
- Track status changes (ACCOUNT_STATUS, BALANCE_LIMIT, INTEREST_RATE) as versioned rows
- Do NOT filter IS_DELETED rows — closed accounts must remain in history',
         9),

        ('EMPLOYEES', 'SILVER', 'master_dimension_scd2',
         'EMPLOYEES is a master dimension. Apply SCD Type 2:
- Primary key: EMPLOYEE_ID
- Add EFFECTIVE_FROM TIMESTAMP_NTZ, EFFECTIVE_TO TIMESTAMP_NTZ DEFAULT NULL, IS_CURRENT BOOLEAN DEFAULT TRUE
- Track role, branch, and title changes as versioned rows
- Required for branch productivity and compliance reporting at a point in time',
         9),

        ('BRANCHES', 'SILVER', 'master_dimension_scd2',
         'BRANCHES is a master dimension. Apply SCD Type 2:
- Primary key: BRANCH_ID
- Add EFFECTIVE_FROM TIMESTAMP_NTZ, EFFECTIVE_TO TIMESTAMP_NTZ DEFAULT NULL, IS_CURRENT BOOLEAN DEFAULT TRUE
- Track branch name, region, and status changes over time',
         9),

        ('CLIENT_PROFILES', 'SILVER', 'master_dimension_scd2',
         'CLIENT_PROFILES is a master dimension for wealth management clients. Apply SCD Type 2:
- Primary key: CLIENT_ID
- Add EFFECTIVE_FROM TIMESTAMP_NTZ, EFFECTIVE_TO TIMESTAMP_NTZ DEFAULT NULL, IS_CURRENT BOOLEAN DEFAULT TRUE
- Track risk tolerance, investment profile, and AUM tier changes as versioned rows',
         9),

        ('KYC_RECORDS', 'SILVER', 'master_dimension_scd2',
         'KYC_RECORDS is a regulatory master table. Apply SCD Type 2:
- Primary key: KYC_ID or CUSTOMER_ID (whichever is the natural key)
- Add EFFECTIVE_FROM TIMESTAMP_NTZ, EFFECTIVE_TO TIMESTAMP_NTZ DEFAULT NULL, IS_CURRENT BOOLEAN DEFAULT TRUE
- Regulatory requirement: every KYC state change must be preserved with full timestamp audit trail
- Do NOT filter any rows — complete KYC history is required for AML compliance',
         9),

        ('FINANCIAL_PRODUCTS', 'SILVER', 'master_dimension_scd2',
         'FINANCIAL_PRODUCTS is a product master dimension. Apply SCD Type 2:
- Primary key: PRODUCT_ID
- Add EFFECTIVE_FROM TIMESTAMP_NTZ, EFFECTIVE_TO TIMESTAMP_NTZ DEFAULT NULL, IS_CURRENT BOOLEAN DEFAULT TRUE
- Track rate changes, fee structure changes, and product lifecycle (active/discontinued) as versioned rows',
         9),

        ('PORTFOLIOS', 'SILVER', 'master_dimension_scd2',
         'PORTFOLIOS is a master dimension for investment portfolios. Apply SCD Type 2:
- Primary key: PORTFOLIO_ID
- Add EFFECTIVE_FROM TIMESTAMP_NTZ, EFFECTIVE_TO TIMESTAMP_NTZ DEFAULT NULL, IS_CURRENT BOOLEAN DEFAULT TRUE
- Track mandate changes, benchmark changes, and portfolio status over time',
         9),

        -- ── Immutable financial facts — append-only ────────────────────────────
        -- These are transaction event tables. Once written, records are never
        -- updated. Dedup only on the natural transaction key — preserve all rows.

        ('TRANSACTIONS', 'SILVER', 'immutable_transaction_fact',
         'TRANSACTIONS is an immutable financial fact table — append only:
- Primary key: TRANSACTION_ID
- Deduplicate on TRANSACTION_ID only; retain the single canonical row per transaction
- Do NOT apply keep_latest logic — there is no "latest" version of a completed transaction
- Do NOT filter IS_DELETED rows — transactions are never logically deleted; flag anomalies instead
- Cast AMOUNT columns to NUMBER(18,4) for precision
- TRANSACTION_DATE is the business date; _INGESTED_AT is the load timestamp — preserve both',
         9),

        ('LOAN_PAYMENTS', 'SILVER', 'immutable_transaction_fact',
         'LOAN_PAYMENTS is an immutable payment fact — append only:
- Primary key: PAYMENT_ID
- Deduplicate on PAYMENT_ID only
- Cast PAYMENT_AMOUNT, PRINCIPAL_PAID, INTEREST_PAID to NUMBER(18,4)
- PAYMENT_DATE drives all delinquency and amortisation calculations — validate it is never NULL',
         9),

        ('CARD_AUTHORIZATIONS', 'SILVER', 'immutable_transaction_fact',
         'CARD_AUTHORIZATIONS is an immutable authorisation fact — append only:
- Primary key: AUTHORIZATION_ID
- Deduplicate on AUTHORIZATION_ID only
- PCI REQUIREMENT: CARD_NUMBER must be masked to last 4 digits only: RIGHT(CARD_NUMBER, 4) prefixed with XXXX-XXXX-XXXX-. Never expose full PAN.
- Cast AMOUNT to NUMBER(18,4)',
         9),

        ('WIRE_TRANSFERS', 'SILVER', 'immutable_transaction_fact',
         'WIRE_TRANSFERS is an immutable transfer fact — append only:
- Primary key: TRANSFER_ID
- Deduplicate on TRANSFER_ID only
- Cast AMOUNT to NUMBER(18,4)
- ORIGINATING_ACCOUNT and BENEFICIARY_ACCOUNT are critical for AML analysis — validate not NULL',
         9),

        ('TRANSACTION_DETAILS', 'SILVER', 'immutable_transaction_fact',
         'TRANSACTION_DETAILS is an immutable line-item fact linked to TRANSACTIONS:
- Primary key: DETAIL_ID (or TRANSACTION_ID + LINE_NUMBER composite)
- Deduplicate on natural key only — do not apply keep_latest
- Cast all AMOUNT columns to NUMBER(18,4)',
         9),

        -- ── Compliance, risk, and audit event tables — full history ────────────
        -- These tables are regulatory evidence. No row may be deleted or filtered.

        ('FRAUD_FLAGS', 'SILVER', 'compliance_audit_trail',
         'FRAUD_FLAGS is a regulatory event log — full history required:
- Primary key: FLAG_ID
- Do NOT filter IS_DELETED rows under any circumstances
- Do NOT deduplicate beyond exact duplicates on FLAG_ID
- Preserve every status transition — each row is evidence of a fraud detection event
- FLAGGED_AT timestamp is the legal event timestamp — must not be NULL',
         9),

        ('COMPLIANCE_ALERTS', 'SILVER', 'compliance_audit_trail',
         'COMPLIANCE_ALERTS is a regulatory event log — full history required:
- Primary key: ALERT_ID
- Do NOT filter IS_DELETED rows — alert closures and false-positive resolutions are part of the audit trail
- Preserve all status transitions (OPEN → UNDER_REVIEW → CLOSED)
- Required for AML, BSA, and regulatory examination responses',
         9),

        ('RISK_EVENTS', 'SILVER', 'compliance_audit_trail',
         'RISK_EVENTS is an operational risk event log — full history required:
- Primary key: EVENT_ID
- Do NOT filter IS_DELETED rows
- Preserve all severity changes and resolution events as separate rows
- EVENT_DATE drives risk reporting SLAs — validate not NULL',
         9),

        -- ── PCI-specific table ─────────────────────────────────────────────────

        ('CARDS', 'SILVER', 'pci_card_data',
         'CARDS contains payment card master data — PCI-DSS compliance required:
- Primary key: CARD_ID
- Apply SCD Type 2: track card status changes (ACTIVE, BLOCKED, EXPIRED, CANCELLED) with EFFECTIVE_FROM / EFFECTIVE_TO / IS_CURRENT
- CARD_NUMBER: mask to last 4 digits only — output column as CARD_NUMBER_MASKED = RIGHT(CARD_NUMBER, 4). Do not include full PAN in Silver.
- CVV/CVC: EXCLUDE entirely from Silver — do not pass through under any circumstances
- EXPIRY_DATE: include as-is (not PCI-restricted but handle as sensitive)
- Do NOT filter IS_DELETED rows — card lifecycle history is required for dispute resolution',
         10)
    ;

    RETURN 'Seeded ' || (SELECT COUNT(*) FROM AGENT_FRAMEWORK.TRANSFORMATION_DIRECTIVES WHERE is_active = TRUE)::VARCHAR || ' directives';
END;
$$;

-- ---------------------------------------------------------------------------
-- DIRECTIVES_FOR_TABLE
-- Returns formatted directives for a given Bronze table name, matching
-- on source_table_pattern (supports SQL LIKE pattern matching).
-- Used by WORKFLOW_PLANNER to build its prompt context.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION AGENT_FRAMEWORK.DIRECTIVES_FOR_TABLE(
    table_name  VARCHAR,
    layer       VARCHAR
)
RETURNS TEXT
LANGUAGE SQL
AS
$$
    SELECT LISTAGG(
        '=== DIRECTIVE [' || use_case || '] (priority ' || priority::VARCHAR || ') ===\n' || instructions,
        '\n\n'
    )
    FROM AGENT_FRAMEWORK.ACTIVE_DIRECTIVES
    WHERE table_name LIKE source_table_pattern
      AND (target_layer = UPPER(layer) OR target_layer = 'BOTH')
    ORDER BY priority DESC
$$;
