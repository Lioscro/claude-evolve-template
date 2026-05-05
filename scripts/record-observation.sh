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

# Extract common fields
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
CWD=$(echo "$INPUT" | jq -r '.cwd')

# Resolve and init project
PROJECT_ID=$(resolve_project "$CWD")
init_project "$PROJECT_ID"

OBS_DIR="$EVOLVE_DIR/projects/$PROJECT_ID/observations"
OBS_FILE="$OBS_DIR/$SESSION_ID.jsonl"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── Decide whether we'll write BEFORE acquiring the lock ───────────────────
# Hoisted out of the case block so filtered-out tools don't pay lock latency.
TOOL_NAME=""
MAX_LEN=""
if [[ "$HOOK_EVENT" == "PostToolUse" ]]; then
  TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')

  # Read allowlist and denylist once
  ALLOWLIST=$(read_config '.observations.tool_allowlist[]' "$PROJECT_ID" 2>/dev/null || true)
  DENYLIST=$(read_config '.observations.tool_denylist[]' "$PROJECT_ID" 2>/dev/null || true)

  # If allowlist is non-empty, skip tools NOT in it
  if [[ -n "$ALLOWLIST" ]]; then
    if ! echo "$ALLOWLIST" | grep -qxF "$TOOL_NAME"; then
      exit 0
    fi
  fi

  # If denylist is non-empty, skip tools IN it
  if [[ -n "$DENYLIST" ]]; then
    if echo "$DENYLIST" | grep -qxF "$TOOL_NAME"; then
      exit 0
    fi
  fi

  MAX_LEN=$(read_config '.observations.max_tool_response_length // 500' "$PROJECT_ID" 2>/dev/null || echo "500")
  MAX_LEN=$(validate_numeric "$MAX_LEN" "$_NUMERIC_NONNEG_INT" "500")
fi

# ── Acquire writer lock; on timeout drop the observation rather than block Claude.
# Timeout is 2s -- real contention is sub-millisecond; 2s caps worst-case hook latency.
if ! acquire_writer_lock "${OBS_FILE}.lock" 2; then
  evolve_log "WARN record-observation.sh: writer lock timeout for $OBS_FILE, dropping observation"
  exit 0
fi
# Set EXIT trap AFTER lock-acquire success so timeout-and-exit-0 path doesn't
# release a lock it doesn't hold. Use 2>/dev/null || true so release never errors.
trap 'release_writer_lock "${OBS_FILE}.lock" 2>/dev/null || true' EXIT

# ── Critical section: write happens entirely under the lock. ───────────────
# The writer lock spans the kernel-level open(O_APPEND|O_CREAT) -> write() -> close()
# sequence, which is what serializes us against observe.sh's rename and
# against other concurrent record-observation.sh writers.
case "$HOOK_EVENT" in
  PostToolUse)
    echo "$INPUT" | jq -c --arg ts "$TIMESTAMP" --argjson max_len "$MAX_LEN" '{
      timestamp: $ts,
      session_id: .session_id,
      event: "PostToolUse",
      tool_name: .tool_name,
      tool_input: .tool_input,
      tool_response_summary: (.tool_response // "" | tostring | .[:$max_len]),
      prompt_context: null
    }' >> "$OBS_FILE"
    ;;

  UserPromptSubmit)
    echo "$INPUT" | jq -c --arg ts "$TIMESTAMP" '{
      timestamp: $ts,
      session_id: .session_id,
      event: "UserPromptSubmit",
      tool_name: null,
      tool_input: null,
      tool_response_summary: null,
      prompt_context: .prompt
    }' >> "$OBS_FILE"
    ;;
esac

exit 0
