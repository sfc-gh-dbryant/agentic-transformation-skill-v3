#!/usr/bin/env bash
# =============================================================================
# sync_skill.sh  [v4]
# Syncs v4 branch artifacts → CoCo skill directory.
# Run after any change to SKILL.md, setup/*.sql, or app/streamlit_app_v4.py.
#
# Usage: ./sync_skill.sh
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$HOME/.snowflake/cortex/skills/agentic-transformation-skill-v4"

# Create skill directory if it doesn't exist
if [[ ! -d "$SKILL_DIR" ]]; then
    echo "Creating skill directory: $SKILL_DIR"
    mkdir -p "$SKILL_DIR/setup"
    mkdir -p "$SKILL_DIR/app"
    mkdir -p "$SKILL_DIR/docs"
fi

echo "Syncing v4 repo → skill directory..."
echo "  Source: $REPO_DIR"
echo "  Target: $SKILL_DIR"
echo ""

# SKILL.md
cp "$REPO_DIR/SKILL.md" "$SKILL_DIR/SKILL.md"
echo "✓ SKILL.md"

# v3 foundation setup files (required for v4)
for f in 00_bootstrap.sql 01_transformation_registry.sql 02_schema_contracts.sql \
          03_directives.sql 04a_discover_schema.sql 04b_planner.sql 04c_executor.sql \
          04d_validator.sql 04e_reflector.sql 04f_orchestrator.sql 05_gold_builder.sql \
          06_schema_analyst.sql 07_pipeline_context.sql 08_dcm_export.sql \
          09_banner_config.sql 10_cortex_search.sql 11_semantic_view.sql \
          12_document_ingestion.sql deploy.sh SETUP_ALL.sql cleanup.sql \
          ats_pipeline_semantics.yaml; do
    [ -f "$REPO_DIR/setup/$f" ] && cp "$REPO_DIR/setup/$f" "$SKILL_DIR/setup/$f" && echo "✓ setup/$f"
done

# v4-specific setup files
for f in v4_tools.sql v4_agents.sql v4_multi_agent.sql 08_cost_attribution.sql; do
    [ -f "$REPO_DIR/setup/$f" ] && cp "$REPO_DIR/setup/$f" "$SKILL_DIR/setup/$f" && echo "✓ setup/$f"
done

# Streamlit v4 app
cp "$REPO_DIR/app/streamlit_app_v4.py" "$SKILL_DIR/app/streamlit_app_v4.py"
echo "✓ app/streamlit_app_v4.py"

[ -f "$REPO_DIR/app/requirements.txt" ] && cp "$REPO_DIR/app/requirements.txt" "$SKILL_DIR/app/requirements.txt" && echo "✓ app/requirements.txt"
[ -f "$REPO_DIR/app/snowflake.yml" ] && cp "$REPO_DIR/app/snowflake.yml" "$SKILL_DIR/app/snowflake.yml" && echo "✓ app/snowflake.yml"

# Key docs
for f in v4_architecture.md v4_design_reference.md v3_to_v4_shift.md; do
    [ -f "$REPO_DIR/docs/$f" ] && cp "$REPO_DIR/docs/$f" "$SKILL_DIR/docs/$f" && echo "✓ docs/$f"
done

echo ""
echo "Sync complete. Commit changes to the v4 branch — the skill directory is now in sync."
