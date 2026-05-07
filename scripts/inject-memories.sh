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

# Extract cwd from hook input
CWD=$(echo "$INPUT" | jq -r '.cwd')

# Resolve project
PROJECT_ID=$(resolve_project "$CWD")

TAB=$'\t'

# Pre-initialize accumulators (set -u safety: must exist before any conditional skip).
PROJECT_OUTPUT=""
GLOBAL_OUTPUT=""

# ── Project memory injection ─────────────────────────────────────────────────

PROJECT_INDEX="$EVOLVE_DIR/projects/$PROJECT_ID/memory/index.yaml"
PROJECT_MEM_DIR="$EVOLVE_DIR/projects/$PROJECT_ID/memory"
if [[ -s "$PROJECT_INDEX" ]]; then
  ALL_PROJECT=$(yq ".memories[] | .id + \"${TAB}\" + .file" "$PROJECT_INDEX" 2>/dev/null || true)
  if [[ -n "$ALL_PROJECT" ]]; then
    while IFS=$'\t' read -r MEM_ID MEM_FILE; do
      [[ -z "$MEM_ID" ]] && continue
      MEM_PATH="$PROJECT_MEM_DIR/$MEM_FILE"
      if [[ ! -f "$MEM_PATH" ]]; then
        evolve_log "WARN inject-memories.sh: index references missing file $MEM_PATH (project $PROJECT_ID); skipping"
        continue
      fi
      PROJECT_OUTPUT+="=== ${MEM_ID} ==="$'\n'
      PROJECT_OUTPUT+="$(cat "$MEM_PATH")"$'\n\n'
    done <<< "$ALL_PROJECT"
  fi
fi

# ── Global memory injection ──────────────────────────────────────────────────

GLOBAL_INDEX="$GLOBAL_DIR/memory/index.yaml"
GLOBAL_MEM_DIR="$GLOBAL_DIR/memory"
if [[ -s "$GLOBAL_INDEX" ]]; then
  ALL_GLOBAL=$(yq ".memories[] | .id + \"${TAB}\" + .file" "$GLOBAL_INDEX" 2>/dev/null || true)
  if [[ -n "$ALL_GLOBAL" ]]; then
    while IFS=$'\t' read -r MEM_ID MEM_FILE; do
      [[ -z "$MEM_ID" ]] && continue
      MEM_PATH="$GLOBAL_MEM_DIR/$MEM_FILE"
      if [[ ! -f "$MEM_PATH" ]]; then
        evolve_log "WARN inject-memories.sh: index references missing file $MEM_PATH (global); skipping"
        continue
      fi
      GLOBAL_OUTPUT+="=== ${MEM_ID} ==="$'\n'
      GLOBAL_OUTPUT+="$(cat "$MEM_PATH")"$'\n\n'
    done <<< "$ALL_GLOBAL"
  fi
fi

# ── Output ───────────────────────────────────────────────────────────────────
# Exit silently if nothing to output from either section.
if [[ -z "$PROJECT_OUTPUT" ]] && [[ -z "$GLOBAL_OUTPUT" ]]; then
  exit 0
fi

if [[ -n "$PROJECT_OUTPUT" ]]; then
  echo "[claude-evolve] Active memories for this project:"
  echo -n "$PROJECT_OUTPUT"
fi

if [[ -n "$GLOBAL_OUTPUT" ]]; then
  echo "[claude-evolve] Active global memories:"
  echo -n "$GLOBAL_OUTPUT"
fi

exit 0
