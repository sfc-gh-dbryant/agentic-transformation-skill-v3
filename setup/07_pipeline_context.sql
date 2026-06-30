-- =============================================================================
-- 07_pipeline_context.sql  [v3]
-- PIPELINE_CONTEXT: one-row table capturing business intent and safety config.
--
-- v3 additions (P0 safety):
--   output_schema      Target schema for all CTAS/DT output.
--                      DEFAULT 'AGENT_FRAMEWORK_OUTPUT'. Never hardcoded to SILVER/GOLD.
--   dry_run            TRUE (default) = generate DDL and log it, do NOT execute.
--                      Must be explicitly set to FALSE to write data.
--   overwrite_existing FALSE (default) = ABORT if target table already has rows.
--                      TRUE = allow overwrite (requires dry_run = FALSE).
-- pipeline_type:       'CTAS' (default) or 'DYNAMIC_TABLE'
-- target_lag:          only used when pipeline_type = 'DYNAMIC_TABLE'
-- gold_output_mode:    'FLAT' (default), 'STAR_SCHEMA', 'DATA_VAULT', 'ONE_BIG_TABLE'
-- brownfield_mode:     FALSE (default) = build mode. TRUE = skip existing Silver tables
--                      instead of aborting. Use when customer already has Silver tables
--                      built outside ATS that should not be rebuilt.
-- conflict_fallback_schema:
--                      NULL (default) = auto-derive as output_schema || '_STAGING'.
--                      Set explicitly to redirect conflicting objects to a specific schema.
--                      Applies to Silver (Executor) and Gold (Gold Builder).
--                      A conflict is: VIEW, DYNAMIC TABLE, or empty regular table at target.
-- =============================================================================

USE DATABASE IDENTIFIER($TARGET_DB);

CREATE TABLE IF NOT EXISTS AGENT_FRAMEWORK.PIPELINE_CONTEXT (
    context_id          INTEGER       NOT NULL DEFAULT 1,
    business_desc       VARCHAR(4000),
    data_domain         VARCHAR(200),
    gold_goals          VARCHAR(4000),
    constraints         VARCHAR(2000),
    pipeline_type       VARCHAR(20)   NOT NULL DEFAULT 'CTAS',
    target_lag          VARCHAR(50)   NOT NULL DEFAULT '1 hour',
    output_schema       VARCHAR(200)  NOT NULL DEFAULT 'AGENT_FRAMEWORK_OUTPUT',
    dry_run             BOOLEAN       NOT NULL DEFAULT TRUE,
    overwrite_existing  BOOLEAN       NOT NULL DEFAULT FALSE,
    gold_output_mode    VARCHAR(20)   NOT NULL DEFAULT 'FLAT',
    brownfield_mode          BOOLEAN       NOT NULL DEFAULT FALSE,
    conflict_fallback_schema VARCHAR                DEFAULT NULL,
    set_by                   VARCHAR                DEFAULT CURRENT_USER(),
    set_at              TIMESTAMP_NTZ          DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_pipeline_context PRIMARY KEY (context_id),
    CONSTRAINT chk_pipeline_type    CHECK (pipeline_type    IN ('CTAS', 'DYNAMIC_TABLE')),
    CONSTRAINT chk_gold_output_mode CHECK (gold_output_mode IN ('FLAT', 'STAR_SCHEMA', 'DATA_VAULT', 'ONE_BIG_TABLE'))
);

INSERT INTO AGENT_FRAMEWORK.PIPELINE_CONTEXT (context_id)
SELECT 1
WHERE NOT EXISTS (
    SELECT 1 FROM AGENT_FRAMEWORK.PIPELINE_CONTEXT WHERE context_id = 1
);


-- ---------------------------------------------------------------------------
-- Helper functions (read by Executor, Planner, Orchestrator)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION AGENT_FRAMEWORK.PIPELINE_CONTEXT_AS_PROMPT()
RETURNS VARCHAR
AS
$$
    SELECT
        CASE
            WHEN business_desc IS NULL AND data_domain IS NULL
                AND gold_goals IS NULL AND constraints IS NULL
            THEN NULL
            ELSE
                COALESCE('Business: ' || business_desc, '') ||
                COALESCE('\nDomain: '           || data_domain,  '') ||
                COALESCE('\nAnalytics Goals: '  || gold_goals,   '') ||
                COALESCE('\nConstraints: '       || constraints,  '')
        END
    FROM AGENT_FRAMEWORK.PIPELINE_CONTEXT
    WHERE context_id = 1
$$;

CREATE OR REPLACE FUNCTION AGENT_FRAMEWORK.PIPELINE_TYPE()
RETURNS VARCHAR
AS
$$
    SELECT COALESCE(pipeline_type, 'CTAS')
    FROM AGENT_FRAMEWORK.PIPELINE_CONTEXT
    WHERE context_id = 1
$$;

CREATE OR REPLACE FUNCTION AGENT_FRAMEWORK.TARGET_LAG()
RETURNS VARCHAR
AS
$$
    SELECT COALESCE(target_lag, '1 hour')
    FROM AGENT_FRAMEWORK.PIPELINE_CONTEXT
    WHERE context_id = 1
$$;

CREATE OR REPLACE FUNCTION AGENT_FRAMEWORK.OUTPUT_SCHEMA()
RETURNS VARCHAR
AS
$$
    SELECT COALESCE(NULLIF(output_schema, ''), 'AGENT_FRAMEWORK_OUTPUT')
    FROM AGENT_FRAMEWORK.PIPELINE_CONTEXT
    WHERE context_id = 1
$$;

CREATE OR REPLACE FUNCTION AGENT_FRAMEWORK.IS_DRY_RUN()
RETURNS BOOLEAN
AS
$$
    SELECT COALESCE(dry_run, TRUE)
    FROM AGENT_FRAMEWORK.PIPELINE_CONTEXT
    WHERE context_id = 1
$$;

CREATE OR REPLACE FUNCTION AGENT_FRAMEWORK.ALLOW_OVERWRITE()
RETURNS BOOLEAN
AS
$$
    SELECT COALESCE(overwrite_existing, FALSE)
    FROM AGENT_FRAMEWORK.PIPELINE_CONTEXT
    WHERE context_id = 1
$$;

-- ---------------------------------------------------------------------------
-- SET_PIPELINE_CONTEXT
-- Named parameters with defaults. Returns a summary object so callers can
-- confirm what was set before proceeding.
-- ---------------------------------------------------------------------------

-- Drop old signatures before re-creating (avoids DEFAULT overload ambiguity)
DROP PROCEDURE IF EXISTS AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, BOOLEAN, BOOLEAN);
DROP PROCEDURE IF EXISTS AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, BOOLEAN, BOOLEAN, VARCHAR);
DROP PROCEDURE IF EXISTS AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, BOOLEAN, BOOLEAN, VARCHAR, VARCHAR);

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT(
    p_business_desc      VARCHAR  DEFAULT NULL,
    p_data_domain        VARCHAR  DEFAULT NULL,
    p_gold_goals         VARCHAR  DEFAULT NULL,
    p_constraints        VARCHAR  DEFAULT NULL,
    p_pipeline_type      VARCHAR  DEFAULT 'CTAS',
    p_target_lag         VARCHAR  DEFAULT '1 hour',
    p_output_schema      VARCHAR  DEFAULT 'AGENT_FRAMEWORK_OUTPUT',
    p_dry_run            BOOLEAN  DEFAULT TRUE,
    p_overwrite_existing     BOOLEAN  DEFAULT FALSE,
    p_gold_output_mode       VARCHAR  DEFAULT 'FLAT',
    p_conflict_fallback_schema VARCHAR DEFAULT NULL
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    IF (UPPER(:p_pipeline_type) NOT IN ('CTAS', 'DYNAMIC_TABLE')) THEN
        RETURN 'ERROR: pipeline_type must be CTAS or DYNAMIC_TABLE. Got: ' || :p_pipeline_type;
    END IF;

    IF (UPPER(:p_gold_output_mode) NOT IN ('FLAT', 'STAR_SCHEMA', 'DATA_VAULT', 'ONE_BIG_TABLE')) THEN
        RETURN 'ERROR: gold_output_mode must be FLAT, STAR_SCHEMA, DATA_VAULT, or ONE_BIG_TABLE. Got: ' || :p_gold_output_mode;
    END IF;

    IF (:p_overwrite_existing AND :p_dry_run) THEN
        RETURN 'ERROR: overwrite_existing=TRUE requires dry_run=FALSE. Set dry_run=>FALSE explicitly to enable overwrites.';
    END IF;

    UPDATE AGENT_FRAMEWORK.PIPELINE_CONTEXT
    SET
        business_desc      = :p_business_desc,
        data_domain        = :p_data_domain,
        gold_goals         = :p_gold_goals,
        constraints        = :p_constraints,
        pipeline_type      = UPPER(:p_pipeline_type),
        target_lag         = :p_target_lag,
        output_schema      = COALESCE(NULLIF(:p_output_schema, ''), 'AGENT_FRAMEWORK_OUTPUT'),
        dry_run            = :p_dry_run,
        overwrite_existing        = :p_overwrite_existing,
        gold_output_mode          = UPPER(:p_gold_output_mode),
        conflict_fallback_schema  = NULLIF(:p_conflict_fallback_schema, ''),
        set_by                    = CURRENT_USER(),
        set_at                    = CURRENT_TIMESTAMP()
    WHERE context_id = 1;

    RETURN OBJECT_CONSTRUCT(
        'pipeline_type',             UPPER(:p_pipeline_type),
        'target_lag',                :p_target_lag,
        'output_schema',             COALESCE(NULLIF(:p_output_schema, ''), 'AGENT_FRAMEWORK_OUTPUT'),
        'dry_run',                   :p_dry_run,
        'overwrite_existing',        :p_overwrite_existing,
        'gold_output_mode',          UPPER(:p_gold_output_mode),
        'conflict_fallback_schema',  :p_conflict_fallback_schema,
        'set_by',                    CURRENT_USER()
    )::VARCHAR;
END;
$$;

-- ---------------------------------------------------------------------------
-- SET_BROWNFIELD_MODE  (separate SP — avoids DEFAULT overload ambiguity)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.SET_BROWNFIELD_MODE(
    p_brownfield_mode BOOLEAN
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    UPDATE AGENT_FRAMEWORK.PIPELINE_CONTEXT
    SET brownfield_mode = :p_brownfield_mode,
        set_by          = CURRENT_USER(),
        set_at          = CURRENT_TIMESTAMP()
    WHERE context_id = 1;
    RETURN OBJECT_CONSTRUCT(
        'brownfield_mode', :p_brownfield_mode,
        'set_by', CURRENT_USER()
    )::VARCHAR;
END;
$$;

-- ---------------------------------------------------------------------------
-- SET_CONFLICT_FALLBACK_SCHEMA
-- Sets the schema ATS redirects output to when a conflict is detected:
--   - Target is a VIEW
--   - Target is a DYNAMIC TABLE
--   - Target is a regular table with 0 rows (owned by another pipeline)
-- Applies to both Silver (Executor) and Gold (Gold Builder).
-- Pass NULL to use auto-derive: output_schema || '_STAGING'.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.SET_CONFLICT_FALLBACK_SCHEMA(
    p_conflict_fallback_schema VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    UPDATE AGENT_FRAMEWORK.PIPELINE_CONTEXT
    SET conflict_fallback_schema = NULLIF(:p_conflict_fallback_schema, ''),
        set_by                   = CURRENT_USER(),
        set_at                   = CURRENT_TIMESTAMP()
    WHERE context_id = 1;
    RETURN OBJECT_CONSTRUCT(
        'conflict_fallback_schema', :p_conflict_fallback_schema,
        'note', CASE
                    WHEN :p_conflict_fallback_schema IS NULL
                    THEN 'Auto-derive mode: fallback = output_schema || ''_STAGING'''
                    ELSE 'Explicit fallback schema set'
                END,
        'set_by', CURRENT_USER()
    )::VARCHAR;
END;
$$;
