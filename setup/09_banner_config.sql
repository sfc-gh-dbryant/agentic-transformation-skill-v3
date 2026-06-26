-- =============================================================================
-- 09_banner_config.sql  [v3 NEW]
-- PARTNER_BANNER_CONFIG: Maps partner banners to their Silver source and Gold
-- target tables, supporting multi-banner partners like LCL V2 (14 banners,
-- 13 Gold tables).
--
-- Architecture:
--   1 Bronze source -> 1 Silver staging table -> N banners -> N Gold tables
--
-- Key concepts:
--   banner_column:       Column in Silver that identifies the banner (e.g. BANNER)
--   gold_table:          Target Gold table name for this banner. NULL = excluded
--   merge_into_banner:   If set, rows route into another banner's Gold table
--   excluded_categories: Comma-separated categories excluded from Gold (e.g. 'Ancillary,Liquor')
--   upc_threshold_pct:   Acceptable % of non-standard UPCs. Default 0 (strict).
-- =============================================================================

USE DATABASE IDENTIFIER($TARGET_DB);

CREATE TABLE IF NOT EXISTS AGENT_FRAMEWORK.PARTNER_BANNER_CONFIG (
    config_id            INTEGER       NOT NULL AUTOINCREMENT,
    partner_name         VARCHAR(200)  NOT NULL,
    bronze_table         VARCHAR(200)  NOT NULL,
    silver_table         VARCHAR(200)  NOT NULL,
    banner_column        VARCHAR(200),
    banner_value         VARCHAR(200),
    gold_table           VARCHAR(200),
    merge_into_banner    VARCHAR(200),
    excluded_categories  VARCHAR(2000),
    upc_threshold_pct    FLOAT         NOT NULL DEFAULT 0.0,
    is_active            BOOLEAN       NOT NULL DEFAULT TRUE,
    notes                VARCHAR(2000),
    created_at           TIMESTAMP_NTZ          DEFAULT CURRENT_TIMESTAMP(),
    created_by           VARCHAR                DEFAULT CURRENT_USER(),
    CONSTRAINT pk_banner_config PRIMARY KEY (config_id)
);

-- ---------------------------------------------------------------------------
-- GET_BANNER_CONFIG
-- Returns all active banner entries for a partner as an ARRAY.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION AGENT_FRAMEWORK.GET_BANNER_CONFIG(p_partner_name VARCHAR)
RETURNS ARRAY
AS
$$
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
        'config_id',           config_id,
        'partner_name',        partner_name,
        'bronze_table',        bronze_table,
        'silver_table',        silver_table,
        'banner_column',       banner_column,
        'banner_value',        banner_value,
        'gold_table',          gold_table,
        'merge_into_banner',   merge_into_banner,
        'excluded_categories', excluded_categories,
        'upc_threshold_pct',   upc_threshold_pct,
        'notes',               notes
    ))
    FROM AGENT_FRAMEWORK.PARTNER_BANNER_CONFIG
    WHERE UPPER(partner_name) = UPPER(p_partner_name)
      AND is_active = TRUE
    ORDER BY config_id
$$;

-- ---------------------------------------------------------------------------
-- VALIDATE_MULTI_BANNER  [v3 - Python rewrite per P1 recommendation]
-- Validates all Gold tables for a multi-banner partner against their
-- corresponding Silver subsets.
--
-- Rewritten as Python SP for maintainability:
--   - f-strings replace multi-layer SQL quote escaping
--   - Each check is an isolated helper function with its own try/except
--   - Loops cleanly through N banners without cursor/RESULTSET boilerplate
--   - Any data engineer can read and extend this without Snowflake scripting expertise
--
-- Accounts for:
--   - Per-banner Silver filters (WHERE BANNER = 'X')
--   - Gold exclusion filters: validates Gold = Silver - excluded (not Silver = Gold)
--   - Merge targets (e.g. ICM -> independent): skipped, validated at merge target
--   - Banners with no Gold table: SKIPPED with INFO, not FAIL
--   - 1% row count variance tolerance
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.VALIDATE_MULTI_BANNER(
    p_partner_name  VARCHAR,
    p_database      VARCHAR  DEFAULT NULL
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS $$
TOLERANCE = 0.01  # 1% row count variance allowed


def count_rows(session, sql):
    """Execute a COUNT(*) query and return the integer result."""
    return session.sql(sql).collect()[0][0]


def check_silver_rows(session, silver_fqn, banner_col, banner_val):
    """Count Silver rows for this banner (filtered by banner column if present)."""
    if banner_col and banner_val:
        sql = f"SELECT COUNT(*) FROM {silver_fqn} WHERE UPPER({banner_col}) = UPPER('{banner_val}')"
    else:
        sql = f"SELECT COUNT(*) FROM {silver_fqn}"
    return count_rows(session, sql)


def check_excluded_rows(session, silver_fqn, banner_col, banner_val, excl_cats):
    """Count rows excluded from Gold (e.g. Ancillary, Liquor categories)."""
    if not excl_cats:
        return 0
    cats = [f"'{c.strip()}'" for c in excl_cats.split(',') if c.strip()]
    if not cats:
        return 0
    cat_list = ', '.join(cats)
    if banner_col and banner_val:
        sql = (
            f"SELECT COUNT(*) FROM {silver_fqn} "
            f"WHERE UPPER({banner_col}) = UPPER('{banner_val}') "
            f"AND category IN ({cat_list})"
        )
    else:
        sql = f"SELECT COUNT(*) FROM {silver_fqn} WHERE category IN ({cat_list})"
    return count_rows(session, sql)


def check_gold_rows(session, gold_fqn):
    """Count rows in the Gold table."""
    return count_rows(session, f"SELECT COUNT(*) FROM {gold_fqn}")


def compute_variance(expected, actual):
    """Return variance as a fraction (0.0 = perfect match)."""
    if expected == 0 and actual == 0:
        return 0.0
    if expected == 0:
        return 1.0
    return abs(actual - expected) / float(expected)


def run(session, p_partner_name, p_database=None):
    current_db = p_database or session.sql("SELECT CURRENT_DATABASE()").collect()[0][0]

    rows = session.sql(
        f"SELECT banner_column, banner_value, gold_table, silver_table, "
        f"excluded_categories, merge_into_banner, upc_threshold_pct "
        f"FROM AGENT_FRAMEWORK.PARTNER_BANNER_CONFIG "
        f"WHERE UPPER(partner_name) = UPPER('{p_partner_name}') AND is_active = TRUE "
        f"ORDER BY config_id"
    ).collect()

    if not rows:
        return {
            'status': 'ERROR',
            'message': (
                f"No banner config found for partner: {p_partner_name}. "
                "Add rows to AGENT_FRAMEWORK.PARTNER_BANNER_CONFIG first."
            )
        }

    results = []
    pass_count = fail_count = skip_count = banner_count = 0

    for row in rows:
        banner_col   = row[0]
        banner_val   = row[1]
        gold_tbl     = row[2]
        silver_tbl   = row[3]
        excl_cats    = row[4]
        merge_target = row[5]

        banner_count += 1
        # If the stored FQN already has 2+ dots it's fully qualified — use as-is.
        # If it has only 1 dot (schema.table) prepend the database override.
        def resolve_fqn(tbl, db):
            if not tbl:
                return None
            return tbl if tbl.count('.') >= 2 else f"{db}.{tbl}"

        silver_fqn = resolve_fqn(silver_tbl, current_db)
        gold_fqn   = resolve_fqn(gold_tbl,   current_db)

        # Banners with no Gold table are skipped (not a failure)
        if not gold_tbl:
            skip_count += 1
            results.append({
                'banner': banner_val,
                'status': 'SKIPPED',
                'reason': 'No Gold table configured for this banner'
            })
            continue

        # Banners that merge into another are validated at the merge target
        if merge_target:
            skip_count += 1
            results.append({
                'banner': banner_val,
                'status': 'SKIPPED',
                'reason': f"Merges into banner: {merge_target}"
            })
            continue

        # Per-banner validation — each check has its own try/except
        try:
            silver_rows   = check_silver_rows(session, silver_fqn, banner_col, banner_val)
            excluded_rows = check_excluded_rows(session, silver_fqn, banner_col, banner_val, excl_cats)

            # Add Silver rows from banners that MERGE INTO this banner's Gold table
            # e.g. independentcitymarket merges into independent — its rows land in LCL_GOLD_INDEPENDENT
            merged_rows = 0
            for merge_row in rows:
                if merge_row[5] == banner_val:  # merge_into_banner == this banner
                    m_banner_val = merge_row[1]
                    m_silver_tbl = merge_row[3]
                    m_silver_fqn = resolve_fqn(m_silver_tbl, current_db)
                    m_excl_cats  = merge_row[4]
                    m_silver = check_silver_rows(session, m_silver_fqn, banner_col, m_banner_val)
                    m_excl   = check_excluded_rows(session, m_silver_fqn, banner_col, m_banner_val, m_excl_cats)
                    merged_rows += (m_silver - m_excl)

            expected_gold = silver_rows - excluded_rows + merged_rows
            gold_rows     = check_gold_rows(session, gold_fqn)
            variance      = compute_variance(expected_gold, gold_rows)
            variance_pct  = round(variance * 100, 2)

            result = {
                'banner':        banner_val,
                'gold_table':    gold_fqn,
                'silver_rows':   silver_rows,
                'excluded_rows': excluded_rows,
                'merged_rows':   merged_rows,
                'expected_gold': expected_gold,
                'gold_rows':     gold_rows,
                'variance_pct':  variance_pct,
            }

            if variance <= TOLERANCE:
                pass_count += 1
                result['status'] = 'PASS'
            else:
                fail_count += 1
                result['status'] = 'FAIL'
                result['reason'] = (
                    f"Variance {variance_pct}% exceeds {TOLERANCE * 100:.0f}% tolerance"
                )

            results.append(result)

        except Exception as e:
            fail_count += 1
            results.append({
                'banner': banner_val,
                'status': 'ERROR',
                'error':  str(e)[:500]
            })

    return {
        'partner':       p_partner_name,
        'status':        'VALIDATED' if fail_count == 0 else 'VALIDATION_FAILURES',
        'total_banners': banner_count,
        'pass_count':    pass_count,
        'fail_count':    fail_count,
        'skip_count':    skip_count,
        'results':       results
    }
$$;

-- ---------------------------------------------------------------------------
-- SEED_LCL_BANNER_CONFIG
-- Example seed for LCL V2 (Canada's largest grocer). Captures the 14-banner
-- architecture from the v2 feedback report. Adapt table/schema names to env.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE AGENT_FRAMEWORK.SEED_LCL_BANNER_CONFIG(
    p_silver_schema VARCHAR DEFAULT 'SILVER',
    p_gold_schema   VARCHAR DEFAULT 'GOLD'
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    banner_schema VARCHAR;
    gold_schema   VARCHAR;
BEGIN
    banner_schema := :p_silver_schema;
    gold_schema   := :p_gold_schema;

    DELETE FROM AGENT_FRAMEWORK.PARTNER_BANNER_CONFIG
    WHERE UPPER(partner_name) = 'LCL';

    INSERT INTO AGENT_FRAMEWORK.PARTNER_BANNER_CONFIG
        (partner_name, bronze_table, silver_table, banner_column, banner_value,
         gold_table, merge_into_banner, excluded_categories, upc_threshold_pct, notes)
    VALUES
        ('LCL', 'BRONZE.LCL_PRODUCTS',      :banner_schema || '.LCL_PRODUCTS_SILVER',     'BANNER', 'superstore',            :gold_schema || '.LCL_GOLD_SUPERSTORE',    NULL,          'Ancillary,Liquor', 30.0, NULL),
        ('LCL', 'BRONZE.LCL_PRODUCTS',      :banner_schema || '.LCL_PRODUCTS_SILVER',     'BANNER', 'nofrills',              :gold_schema || '.LCL_GOLD_NOFRILLS',       NULL,          'Ancillary,Liquor', 30.0, NULL),
        ('LCL', 'BRONZE.LCL_PRODUCTS',      :banner_schema || '.LCL_PRODUCTS_SILVER',     'BANNER', 'maxi',                  :gold_schema || '.LCL_GOLD_MAXI',           NULL,          'Ancillary,Liquor', 30.0, NULL),
        ('LCL', 'BRONZE.LCL_PRODUCTS',      :banner_schema || '.LCL_PRODUCTS_SILVER',     'BANNER', 'independent',           :gold_schema || '.LCL_GOLD_INDEPENDENT',    NULL,          'Ancillary,Liquor', 30.0, NULL),
        ('LCL', 'BRONZE.LCL_PRODUCTS',      :banner_schema || '.LCL_PRODUCTS_SILVER',     'BANNER', 'rass',                  :gold_schema || '.LCL_GOLD_RASS',           NULL,          'Ancillary,Liquor', 30.0, NULL),
        ('LCL', 'BRONZE.LCL_PRODUCTS',      :banner_schema || '.LCL_PRODUCTS_SILVER',     'BANNER', 'zehrs',                 :gold_schema || '.LCL_GOLD_ZEHRS',          NULL,          'Ancillary,Liquor', 30.0, 'Zehrs Silver is pre-dedup staging containing all banners — use LCL_PRODUCTS_SILVER'),
        ('LCL', 'BRONZE.LCL_PRODUCTS',      :banner_schema || '.LCL_PRODUCTS_SILVER',     'BANNER', 'loblaws',               :gold_schema || '.LCL_GOLD_LOBLAWS',        NULL,          'Ancillary,Liquor', 30.0, NULL),
        ('LCL', 'BRONZE.LCL_PRODUCTS',      :banner_schema || '.LCL_PRODUCTS_SILVER',     'BANNER', 'wholesaleclub',         :gold_schema || '.LCL_GOLD_WHOLESALECLUB',  NULL,          'Ancillary,Liquor', 30.0, NULL),
        ('LCL', 'BRONZE.LCL_PRODUCTS',      :banner_schema || '.LCL_PRODUCTS_SILVER',     'BANNER', 'fortinos',              :gold_schema || '.LCL_GOLD_FORTINOS',       NULL,          'Ancillary,Liquor', 30.0, NULL),
        ('LCL', 'BRONZE.LCL_PRODUCTS',      :banner_schema || '.LCL_PRODUCTS_SILVER',     'BANNER', 'dominion',              :gold_schema || '.LCL_GOLD_DOMINION',       NULL,          'Ancillary,Liquor', 30.0, NULL),
        ('LCL', 'BRONZE.LCL_PRODUCTS',      :banner_schema || '.LCL_PRODUCTS_SILVER',     'BANNER', 'provigo',               :gold_schema || '.LCL_GOLD_PROVIGO',        NULL,          'Ancillary,Liquor', 30.0, NULL),
        ('LCL', 'BRONZE.LCL_PRODUCTS',      :banner_schema || '.LCL_PRODUCTS_SILVER',     'BANNER', 'valumart',              :gold_schema || '.LCL_GOLD_VALUMART',       NULL,          'Ancillary,Liquor', 30.0, NULL),
        ('LCL', 'BRONZE.LCL_PRODUCTS',      :banner_schema || '.LCL_PRODUCTS_SILVER',     'BANNER', 'independentcitymarket', :gold_schema || '.LCL_GOLD_INDEPENDENT',    'independent', 'Ancillary,Liquor', 30.0, 'ICM merges into independent Gold table'),
        ('LCL', 'BRONZE.LCL_PRODUCTS',      :banner_schema || '.LCL_PRODUCTS_SILVER',     'BANNER', 'your ind grocer',       NULL,                                       NULL,          NULL,               30.0, 'No Gold table for this banner');

    RETURN 'Seeded 14 banner config rows for LCL. Update table/schema names as needed.';
END;
$$;
