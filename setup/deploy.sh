#!/usr/bin/env bash
# =============================================================================
# deploy.sh  [v3]
# Deploys the Agentic Transformation Skill v3 to a Snowflake database.
# Runs scripts 00-11 in dependency order, then calls BOOTSTRAP.
#
# Script order:
#   00  Schema + MODEL_CONFIG + BOOTSTRAP + RESET_FRAMEWORK
#   01  Registry tables
#   02  Schema Contracts
#   03  Transformation Directives
#   04a  Discover Schema SP
#   04b  Planner SP
#   04c  Executor SP         [v3: dry_run, safe output_schema, cross-db column injection]
#   04d  Validator SP        [v3: pk_columns from PLANNER_DECISIONS]
#   04e  Reflector SP
#   04f  Orchestrator SP
#   05  Gold Builder
#   06  Schema Analyst
#   07  Pipeline Context  [v3: output_schema, dry_run, overwrite_existing]
#   08  DCM Export
#   09  Banner Config     [v3 NEW: multi-banner, VALIDATE_MULTI_BANNER]
#   10  Cortex Search     [v3 NEW: ATS_KNOWLEDGE_CORPUS, ATS_KNOWLEDGE_SEARCH, SEARCH_ATS_KNOWLEDGE]
#   11  Semantic View     [v3 NEW: ATS_PIPELINE_SEMANTICS for Cortex Analyst / Snowflake Intelligence]
#
# Usage:
#   ./setup/deploy.sh \
#     --connection CUSTOMER_CONN \
#     --database   CUSTOMER_DB  \
#     --bronze-schema RAW             # plain schema (same DB as framework)
#
#   Cross-database pattern (framework DB != data DB):
#   ./setup/deploy.sh \
#     --connection CUSTOMER_CONN \
#     --database   ATS_V3           \
#     --bronze-schema CUSTOMER_DB.BRONZE
#
#   Multi-source (LCL V2 pattern):
#   ./setup/deploy.sh \
#     --connection CUSTOMER_CONN \
#     --database   ATS_V3           \
#     --bronze-schema "DB1.BRONZE,DB2.RAW"
#
# Requirements:
#   - snow CLI installed and on PATH
#   - Named connection configured in ~/.snowflake/config.toml
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONNECTION=""
TARGET_DB=""
BRONZE_SCHEMA=""
WAREHOUSE=""

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --connection)   CONNECTION="$2";    shift 2 ;;
        --database)     TARGET_DB="$2";     shift 2 ;;
        --bronze-schema) BRONZE_SCHEMA="$2"; shift 2 ;;
        --warehouse)    WAREHOUSE="$2";     shift 2 ;;
        *)              echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$CONNECTION" || -z "$TARGET_DB" || -z "$BRONZE_SCHEMA" ]]; then
    echo "ERROR: --connection, --database, and --bronze-schema are all required."
    echo ""
    echo "Usage:"
    echo "  ./setup/deploy.sh --connection MY_CONN --database MY_DB --bronze-schema RAW [--warehouse MY_WH]"
    exit 1
fi

# Default warehouse to current session warehouse if not specified
if [[ -z "$WAREHOUSE" ]]; then
    WAREHOUSE=$(snow sql -c "${CONNECTION}" -q "SELECT CURRENT_WAREHOUSE()" 2>/dev/null | grep '|' | grep -v 'CURRENT' | tr -d '| ' | head -1)
    WAREHOUSE=${WAREHOUSE:-COMPUTE_WH}
fi

echo ""
echo "========================================================"
echo "  Agentic Transformation Skill — Deploy"
echo "========================================================"
echo "  Connection:    $CONNECTION"
echo "  Database:      $TARGET_DB"
echo "  Bronze Schema: $BRONZE_SCHEMA"
echo "  Warehouse:     $WAREHOUSE"
echo "========================================================"
echo ""

SET_VARS="SET TARGET_DB = '${TARGET_DB}'; SET BRONZE_SCHEMA = '${BRONZE_SCHEMA}'; SET WAREHOUSE = '${WAREHOUSE}';"

run_script() {
    local script="$1"
    local tmpfile
    tmpfile=$(mktemp /tmp/deploy_XXXXX.sql)
    printf '%s\n' "${SET_VARS}" > "${tmpfile}"
    cat "${SCRIPT_DIR}/${script}" >> "${tmpfile}"
    snow sql -c "${CONNECTION}" -f "${tmpfile}"
    rm -f "${tmpfile}"
}

# Optional scripts: failures are warnings, not blockers
run_script_optional() {
    local script="$1"
    local tmpfile
    tmpfile=$(mktemp /tmp/deploy_XXXXX.sql)
    printf '%s\n' "${SET_VARS}" > "${tmpfile}"
    cat "${SCRIPT_DIR}/${script}" >> "${tmpfile}"
    if snow sql -c "${CONNECTION}" -f "${tmpfile}" 2>&1; then
        echo "✓  $script complete"
    else
        echo "⚠  $script failed (optional — skipping). Deploy the Streamlit app and use Tab 10/11/12 to retry."
    fi
    rm -f "${tmpfile}"
}

# ---------------------------------------------------------------------------
# Run setup scripts in order
# ---------------------------------------------------------------------------

SCRIPTS=(
    "00_bootstrap.sql"
    "01_transformation_registry.sql"
    "02_schema_contracts.sql"
    "03_directives.sql"
    "04a_discover_schema.sql"
    "04b_planner.sql"
    "04c_executor.sql"
    "04d_validator.sql"
    "04e_reflector.sql"
    "04f_orchestrator.sql"
    "05_gold_builder.sql"
    "06_schema_analyst.sql"
    "07_pipeline_context.sql"
    "08_dcm_export.sql"
    "09_banner_config.sql"
)

OPTIONAL_SCRIPTS=(
    "10_cortex_search.sql"
    "11_semantic_view.sql"
    "12_document_ingestion.sql"
)

for script in "${SCRIPTS[@]}"; do
    echo "▶  Running $script ..."
    run_script "${script}"
    echo "✓  $script complete"
    echo ""
done

echo "▶  Running optional enhancement scripts (10-12)..."
for script in "${OPTIONAL_SCRIPTS[@]}"; do
    echo "▶  Running $script ..."
    run_script_optional "${script}"
    echo ""
done

# ---------------------------------------------------------------------------
# Call BOOTSTRAP to initialize: model validation + table discovery + seed
# ---------------------------------------------------------------------------

echo "▶  Running BOOTSTRAP('${BRONZE_SCHEMA}') ..."
BOOTSTRAP_SQL=$(mktemp /tmp/deploy_bootstrap_XXXXX.sql)
printf "SET TARGET_DB = '%s'; USE DATABASE IDENTIFIER(\$TARGET_DB); CALL AGENT_FRAMEWORK.BOOTSTRAP('%s');\n" "${TARGET_DB}" "${BRONZE_SCHEMA}" > "${BOOTSTRAP_SQL}"
snow sql -c "${CONNECTION}" -f "${BOOTSTRAP_SQL}"
rm -f "${BOOTSTRAP_SQL}"

echo ""
echo "========================================================"
echo "  Deploy complete."
echo ""
echo "  Next steps:"
echo "  1. Deploy the Streamlit app to Snowsight:"
echo "     cd app && snow streamlit deploy -c $CONNECTION --replace && cd .."
echo ""
echo "  2. Open Snowsight and navigate to the Streamlit app."
echo "  3. Tab 1 (Setup): verify model = llama3.3-70b and Cortex Intelligence shows ✅"
echo "  4. Tab 2 (Context): set Pipeline Context and confirm dry_run=TRUE"
echo "  5. Tab 5 (Workflow): run agentic workflow to populate knowledge base"
echo "========================================================"
