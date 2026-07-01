#!/usr/bin/env bash
# =============================================================================
# sync_skill.sh
# Syncs v3 repo artifacts → CoCo skill directory.
# Run after any change to SKILL.md, setup/*.sql, or app/streamlit_app.py.
#
# Usage: ./sync_skill.sh
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$HOME/.snowflake/cortex/skills/agentic-transformation-skill"

if [[ ! -d "$SKILL_DIR" ]]; then
    echo "ERROR: Skill directory not found: $SKILL_DIR"
    exit 1
fi

echo "Syncing v3 repo → skill directory..."
echo "  Source: $REPO_DIR"
echo "  Target: $SKILL_DIR"
echo ""

# SKILL.md
cp "$REPO_DIR/SKILL.md" "$SKILL_DIR/SKILL.md"
echo "✓ SKILL.md"

# Setup SQL files
for f in "$REPO_DIR"/setup/*.sql "$REPO_DIR/setup/deploy.sh" "$REPO_DIR/setup/SETUP_ALL.sql" "$REPO_DIR/setup/cleanup.sql" "$REPO_DIR/setup/ats_pipeline_semantics.yaml"; do
    [ -f "$f" ] && cp "$f" "$SKILL_DIR/setup/$(basename "$f")" && echo "✓ setup/$(basename "$f")"
done

# Streamlit app
cp "$REPO_DIR/app/streamlit_app.py" "$SKILL_DIR/app/streamlit_app.py"
echo "✓ app/streamlit_app.py"

cp "$REPO_DIR/app/environment.yml" "$SKILL_DIR/app/environment.yml"
echo "✓ app/environment.yml"

echo ""
echo "Sync complete. Commit changes to the v3 repo — the skill directory is now in sync."
