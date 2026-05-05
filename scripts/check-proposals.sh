#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$HOME/.claude/evolve/scripts/lib.sh"

# Trap errors -- log and exit 0 (never block Claude)
trap 'evolve_trap $LINENO $?' ERR

# ── Arguments ──────────────────────────────────────────────────────────────
PROJECT_ID="${1:?check-proposals.sh requires PROJECT_ID as \$1}"

# ── Paths ──────────────────────────────────────────────────────────────────
PROJECT_DIR="$EVOLVE_DIR/projects/$PROJECT_ID"
INDEX_FILE="$PROJECT_DIR/proposals/index.yaml"

if [[ ! -f "$INDEX_FILE" ]]; then
  exit 0
fi

# Count pending project proposals
PROJECT_COUNT=$(yq '.proposals | length' "$INDEX_FILE" 2>/dev/null || echo 0)

# Count pending global proposals (gracefully handle missing $GLOBAL_DIR)
GLOBAL_COUNT=0
GLOBAL_INDEX="$GLOBAL_DIR/proposals/index.yaml"
if [[ -d "$GLOBAL_DIR" && -f "$GLOBAL_INDEX" ]]; then
  GLOBAL_COUNT=$(yq '.proposals | length' "$GLOBAL_INDEX" 2>/dev/null || echo 0)
fi

if [[ "$PROJECT_COUNT" -gt 0 && "$GLOBAL_COUNT" -gt 0 ]]; then
  echo "[claude-evolve] $PROJECT_COUNT project proposal(s), $GLOBAL_COUNT global promotion proposal(s) pending. Run /evolve to review."
elif [[ "$PROJECT_COUNT" -gt 0 ]]; then
  echo "[claude-evolve] $PROJECT_COUNT pending proposal(s). Run /evolve to review."
elif [[ "$GLOBAL_COUNT" -gt 0 ]]; then
  echo "[claude-evolve] $GLOBAL_COUNT global promotion proposal(s) pending. Run /evolve to review."
fi

exit 0
