#!/usr/bin/env bash
set -euo pipefail

# Read ALL of stdin before anything else (hook input JSON).
INPUT=$(cat)

# Source shared library
source "$HOME/.claude/evolve/scripts/lib.sh"

# Trap errors -- log and exit 0 (never block Claude)
trap 'evolve_trap $LINENO $?' ERR

# Exit early if running inside an evolve agent subprocess
if evolve_is_subprocess; then
  exit 0
fi

# Exit early if evolve is disabled
if ! evolve_enabled; then
  exit 0
fi

# Extract fields
CWD=$(echo "$INPUT" | jq -r '.cwd')

# Resolve and init project
PROJECT_ID=$(resolve_project "$CWD")
init_project "$PROJECT_ID"

# Init global instinct/proposal directories
init_global

# Pull latest instincts/proposals from git (before background writers start)
evolve_git_pull

# Fork observe.sh into background
nohup "$EVOLVE_DIR/scripts/observe.sh" "$PROJECT_ID" >> "$EVOLVE_LOG" 2>&1 &

# Call check-proposals.sh synchronously (Phase 5 -- skip if not yet created)
if [[ -x "$EVOLVE_DIR/scripts/check-proposals.sh" ]]; then
  "$EVOLVE_DIR/scripts/check-proposals.sh" "$PROJECT_ID" 2>/dev/null || true
fi

exit 0
