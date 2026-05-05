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

# Check if stop hook is already active (prevent re-entrant calls)
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
  exit 0
fi

# Extract fields
CWD=$(echo "$INPUT" | jq -r '.cwd')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')

# Resolve project
PROJECT_ID=$(resolve_project "$CWD")

# Fork reinforce-worker.sh into background and exit immediately
nohup "$EVOLVE_DIR/scripts/reinforce-worker.sh" "$PROJECT_ID" "$SESSION_ID" >> "$EVOLVE_LOG" 2>&1 &

exit 0
