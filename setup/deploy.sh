#!/usr/bin/env bash
# =============================================================================
# deploy.sh  [v4]
# Deploys the Agentic Transformation Skill v4 to a Snowflake database.
# Runs all setup scripts in dependency order, then calls BOOTSTRAP.
#
# Script order:
#   00  Schema + MODEL_CONFIG + BOOTSTRAP + RESET_FRAMEWORK
#   01  Registry tables
#   02  Schema Contracts
#   03  Transformation Directives
#   04a  Discover Schema SP      [SQL Scripting]
#   04b  Planner SP              [SQL Scripting]
#   04c  Executor SP             [SQL Scripting — dry_run, safe output_schema, conflict redirect]
#   04d  Validator SP            [SQL Scripting — pk_columns from PLANNER_DECISIONS, cross-db]
#   04e  Reflector SP            [SQL Scripting]
#   04f  Orchestrator SP         [SQL Scripting]
#   05  Gold Builder             [Python SP — conflict redirect for Gold]
#   06  Schema Analyst           [Python SP]
#   07  Pipeline Context         [conflict_fallback_schema added in v4]
#   08  Cost Attribution         [v4 NEW: WORKFLOW_COST_ATTRIBUTION + CAPTURE_WORKFLOW_COST]
#   08  DCM Export
#   09  Banner Config            [multi-banner, VALIDATE_MULTI_BANNER]
#   10  Cortex Search            [ATS_KNOWLEDGE_CORPUS, ATS_KNOWLEDGE_SEARCH]
#   11  Semantic View            [ATS_PIPELINE_SEMANTICS for Cortex Analyst]
#   12  Document Ingestion       [RAG: DOCUMENT_STAGE, DOCUMENT_CONTEXT_ITEMS]
#   v4_tools  ATS_TOOL_* SPs     [v4 NEW: 35 tool stored procedures for Cortex Agents]
#   v4_agents Cortex Agents      [v4 NEW: 6 Cortex Agents — deploy AFTER v4_tools]
#
# NOTE: SQL Scripting SPs (04a-04f) use BEGIN...END syntax. If snow sql -f fails
# on these files due to || concatenation inside $$...$$, deploy them manually
# via Python connector. See docs/v4_architecture.md § Known Limitations.
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
echo "  Agentic Transformation Skill v4 — Deploy"
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
    "08_cost_attribution.sql"
    "08_dcm_export.sql"
    "09_banner_config.sql"
    "10_cortex_search.sql"
    "11_semantic_view.sql"
    "12_document_ingestion.sql"
    "v4_tools.sql"
    "v4_agents.sql"
)

for script in "${SCRIPTS[@]}"; do
    echo "▶  Running $script ..."
    run_script "${script}"
    echo "✓  $script complete"
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
echo ""
echo "  v4 Agent Hub:"
echo "  6. Tab 6 (Agent Hub): interact directly with any of the 6 Cortex Agents"
echo "  7. Tab 7 (Orchestrate): run the full pipeline via ATS_ORCHESTRATOR_AGENT"
echo "========================================================"
