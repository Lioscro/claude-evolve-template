#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$HOME/.claude/evolve/scripts/lib.sh"

# Trap errors -- log and exit 0 (never block Claude)
trap 'evolve_trap $LINENO $?' ERR

# ── Arguments ──────────────────────────────────────────────────────────────
PROJECT_ID="${1:?reinforce-worker.sh requires PROJECT_ID as \$1}"
SESSION_ID="${2:?reinforce-worker.sh requires SESSION_ID as \$2}"

# ── Paths ──────────────────────────────────────────────────────────────────
PROJECT_DIR="$EVOLVE_DIR/projects/$PROJECT_ID"
OBS_DIR="$PROJECT_DIR/observations"
INSTINCTS_DIR="$PROJECT_DIR/instincts"
INDEX_FILE="$INSTINCTS_DIR/index.yaml"
LOCK_FILE="$PROJECT_DIR/evolve.lock"
OBS_FILE="$OBS_DIR/$SESSION_ID.jsonl"

# ── Acquire lock (exit 0 if held -- observe.sh takes priority) ────────────
if ! acquire_lock "$LOCK_FILE"; then
  evolve_log "reinforce-worker.sh: lock held, exiting"
  exit 0
fi
trap 'release_lock "$LOCK_FILE"' EXIT

# ── Read current session's observations ────────────────────────────────────
if [[ ! -f "$OBS_FILE" ]] || [[ ! -s "$OBS_FILE" ]]; then
  evolve_log "reinforce-worker.sh: no observations for session $SESSION_ID"
  exit 0
fi

OBSERVATIONS=$(cat "$OBS_FILE")

# ── Read instinct index ───────────────────────────────────────────────────
INSTINCT_COUNT=0
if [[ -f "$INDEX_FILE" ]]; then
  INSTINCT_COUNT=$(yq '.instincts | length' "$INDEX_FILE" 2>/dev/null || echo "0")
fi

# Check if there are any instincts to reinforce (project or global)
GLOBAL_INDEX_FILE="$GLOBAL_DIR/instincts/index.yaml"
GLOBAL_COUNT=0
if [[ -d "$GLOBAL_DIR" ]] && [[ -f "$GLOBAL_INDEX_FILE" ]]; then
  GLOBAL_COUNT=$(yq '.instincts | length' "$GLOBAL_INDEX_FILE" 2>/dev/null || echo "0")
fi

if [[ "$INSTINCT_COUNT" -eq 0 ]] && [[ "$GLOBAL_COUNT" -eq 0 ]]; then
  evolve_log "reinforce-worker.sh: no instincts to reinforce"
  exit 0
fi

# ── Build agent input ─────────────────────────────────────────────────────
# Build instinct summaries
INSTINCT_YAML=""
if [[ "$INSTINCT_COUNT" -gt 0 ]]; then
  for ((i=0; i<INSTINCT_COUNT; i++)); do
    local_file=$(yq ".instincts[$i].file" "$INDEX_FILE")
    instinct_path="$INSTINCTS_DIR/$local_file"
    if [[ -f "$instinct_path" ]]; then
      INSTINCT_YAML+="$(cat "$instinct_path")"
      INSTINCT_YAML+=$'\n---\n'
    fi
  done
fi

# ── Read global instincts (if available) ──────────────────────────────────
GLOBAL_INSTINCT_YAML=""
if [[ -d "$GLOBAL_DIR" ]] && [[ -f "$GLOBAL_INDEX_FILE" ]] && [[ "$GLOBAL_COUNT" -gt 0 ]]; then
  for ((i=0; i<GLOBAL_COUNT; i++)); do
    local_file=$(yq ".instincts[$i].file" "$GLOBAL_INDEX_FILE")
    instinct_path="$GLOBAL_DIR/instincts/$local_file"
    if [[ -f "$instinct_path" ]]; then
      GLOBAL_INSTINCT_YAML+="$(cat "$instinct_path")"
      GLOBAL_INSTINCT_YAML+=$'\n---\n'
    fi
  done
fi

AGENT_INPUT="## Existing Instincts
${INSTINCT_YAML}

## Global Instincts
${GLOBAL_INSTINCT_YAML}

## Recent Observations
${OBSERVATIONS}"

# ── Invoke reinforcer agent ───────────────────────────────────────────────
AGENT_OUTPUT=$(echo "$AGENT_INPUT" | invoke_agent "$EVOLVE_DIR/agents/reinforcer.md" 2>/dev/null) || {
  evolve_log "reinforce-worker.sh: agent invocation failed"
  exit 0
}

# ── Read config values ────────────────────────────────────────────────────
REINFORCEMENT_INC=$(read_config '.instincts.reinforcement_increment // 0.05' "$PROJECT_ID" 2>/dev/null || echo "0.05")
REINFORCEMENT_INC=$(validate_numeric "$REINFORCEMENT_INC" "$_NUMERIC_NONNEG_FLOAT" "0.05")
MAX_CONFIDENCE=$(read_config '.instincts.max_confidence // 1' "$PROJECT_ID" 2>/dev/null || echo "1")
MAX_CONFIDENCE=$(validate_numeric "$MAX_CONFIDENCE" "$_NUMERIC_NONNEG_FLOAT" "1")
GLOBAL_REINFORCEMENT_INC=$(read_config '.global_instincts.reinforcement_increment // 0.05' "$PROJECT_ID" 2>/dev/null || echo "0.05")
GLOBAL_REINFORCEMENT_INC=$(validate_numeric "$GLOBAL_REINFORCEMENT_INC" "$_NUMERIC_NONNEG_FLOAT" "0.05")
GLOBAL_MAX_CONFIDENCE=$(read_config '.global_instincts.max_confidence // 1' "$PROJECT_ID" 2>/dev/null || echo "1")
GLOBAL_MAX_CONFIDENCE=$(validate_numeric "$GLOBAL_MAX_CONFIDENCE" "$_NUMERIC_NONNEG_FLOAT" "1")

# ── Parse output: REINFORCE lines bump confidence, NONE = do nothing ──────
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
REINFORCED_COUNT=0
GLOBAL_REINFORCE_IDS=""

while IFS= read -r line; do
  line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -z "$line" ]] && continue

  if [[ "$line" =~ ^REINFORCE\ (.+)$ ]]; then
    INSTINCT_ID="${BASH_REMATCH[1]}"

    # Check project instinct first
    if [[ -f "$INSTINCTS_DIR/${INSTINCT_ID}.yaml" ]]; then
      INSTINCT_FILE="$INSTINCTS_DIR/${INSTINCT_ID}.yaml"

      # Skip malformed YAML so one bad file doesn't abort the whole batch.
      if ! yq '.' "$INSTINCT_FILE" >/dev/null 2>&1; then
        evolve_log "reinforce-worker.sh: REINFORCE $INSTINCT_ID -- malformed YAML, skipping"
        continue
      fi

      evolve_log "reinforce-worker.sh: REINFORCE $INSTINCT_ID (project)"
      REINFORCED_COUNT=$((REINFORCED_COUNT + 1))

      # Bump confidence (capped)
      CURRENT_CONF=$(yq '.confidence // 0' "$INSTINCT_FILE" 2>/dev/null || echo "0")
      NEW_CONF=$(bc_calc "$CURRENT_CONF + $REINFORCEMENT_INC")
      if (( $(echo "$NEW_CONF > $MAX_CONFIDENCE" | bc -l) )); then
        NEW_CONF="$MAX_CONFIDENCE"
      fi

      # Increment observation_count
      CURRENT_COUNT=$(yq '.observation_count // 0' "$INSTINCT_FILE" 2>/dev/null || echo "0")
      NEW_COUNT=$((CURRENT_COUNT + 1))

      # Update instinct file
      TMP_INST=$(mktemp)
      yq "
        .confidence = ${NEW_CONF} |
        .observation_count = ${NEW_COUNT} |
        .last_reinforced = \"${NOW}\"
      " "$INSTINCT_FILE" > "$TMP_INST"

      # Add session ID (deduplicate)
      HAS_SID=$(yq "[.source_sessions // [] | .[] | select(. == \"${SESSION_ID}\")] | length" "$TMP_INST" 2>/dev/null || echo "0")
      if [[ "$HAS_SID" == "0" ]]; then
        TMP2=$(mktemp)
        yq ".source_sessions += [\"${SESSION_ID}\"]" "$TMP_INST" > "$TMP2"
        mv "$TMP2" "$TMP_INST"
      fi

      mv "$TMP_INST" "$INSTINCT_FILE"

      # Update confidence in index
      TMP_IDX=$(mktemp)
      yq "(.instincts[] | select(.id == \"${INSTINCT_ID}\")).confidence = ${NEW_CONF}" "$INDEX_FILE" > "$TMP_IDX"
      mv "$TMP_IDX" "$INDEX_FILE"

    # Check global instinct (fallback -- global- prefix prevents ambiguity)
    elif [[ -d "$GLOBAL_DIR" ]] && [[ -f "$GLOBAL_DIR/instincts/${INSTINCT_ID}.yaml" ]]; then
      evolve_log "reinforce-worker.sh: REINFORCE $INSTINCT_ID (global, deferred)"
      GLOBAL_REINFORCE_IDS="${GLOBAL_REINFORCE_IDS}${INSTINCT_ID}"$'\n'

    else
      evolve_log "reinforce-worker.sh: REINFORCE $INSTINCT_ID -- file not found, skipping"
    fi

  elif [[ "$line" == "NONE" ]]; then
    evolve_log "reinforce-worker.sh: no matches"
  fi
done <<< "$AGENT_OUTPUT"

# NO DECAY -- only observe.sh applies decay

# ── Write project index atomically ────────────────────────────────────────
TMP_FINAL=$(mktemp)
cp "$INDEX_FILE" "$TMP_FINAL"
mv "$TMP_FINAL" "$INDEX_FILE"

# ── Release project lock BEFORE acquiring global lock ─────────────────────
release_lock "$LOCK_FILE"
trap - EXIT

# ── Reinforce global instincts (if any matched) ──────────────────────────
GLOBAL_REINFORCED=0
if [[ -n "$GLOBAL_REINFORCE_IDS" ]] && [[ -d "$GLOBAL_DIR" ]]; then
  GLOBAL_LOCK="$GLOBAL_DIR/global.lock"
  if acquire_lock "$GLOBAL_LOCK"; then
    trap 'release_lock "$GLOBAL_LOCK"' EXIT

    while IFS= read -r GID; do
      [[ -z "$GID" ]] && continue
      GFILE="$GLOBAL_DIR/instincts/${GID}.yaml"
      if [[ ! -f "$GFILE" ]]; then
        evolve_log "reinforce-worker.sh: global instinct $GID disappeared, skipping"
        continue
      fi

      if ! yq '.' "$GFILE" >/dev/null 2>&1; then
        evolve_log "reinforce-worker.sh: REINFORCE $GID -- malformed YAML, skipping"
        continue
      fi

      evolve_log "reinforce-worker.sh: REINFORCE $GID (global)"
      GLOBAL_REINFORCED=$((GLOBAL_REINFORCED + 1))

      # Bump confidence (capped)
      CURRENT_CONF=$(yq '.confidence // 0' "$GFILE" 2>/dev/null || echo "0")
      NEW_CONF=$(bc_calc "$CURRENT_CONF + $GLOBAL_REINFORCEMENT_INC")
      if (( $(echo "$NEW_CONF > $GLOBAL_MAX_CONFIDENCE" | bc -l) )); then
        NEW_CONF="$GLOBAL_MAX_CONFIDENCE"
      fi

      # Increment observation_count
      CURRENT_COUNT=$(yq '.observation_count // 0' "$GFILE" 2>/dev/null || echo "0")
      NEW_COUNT=$((CURRENT_COUNT + 1))

      # Update global instinct file (no source_sessions for global instincts)
      TMP_GINST=$(mktemp)
      yq "
        .confidence = ${NEW_CONF} |
        .observation_count = ${NEW_COUNT} |
        .last_reinforced = \"${NOW}\"
      " "$GFILE" > "$TMP_GINST"
      mv "$TMP_GINST" "$GFILE"

      # Update confidence in global index
      TMP_GIDX=$(mktemp)
      yq "(.instincts[] | select(.id == \"${GID}\")).confidence = ${NEW_CONF}" "$GLOBAL_INDEX_FILE" > "$TMP_GIDX"
      mv "$TMP_GIDX" "$GLOBAL_INDEX_FILE"
    done <<< "$GLOBAL_REINFORCE_IDS"

    release_lock "$GLOBAL_LOCK"
    trap - EXIT
  else
    evolve_log "reinforce-worker.sh: global lock held, skipping global reinforcement"
  fi
fi

TOTAL_REINFORCED=$((REINFORCED_COUNT + GLOBAL_REINFORCED))

# ── Sync to git (after all updates including global) ──────────────────────
evolve_git_push "evolve(reinforce): reinforced ${TOTAL_REINFORCED} instinct(s)"

evolve_log "reinforce-worker.sh: done"
exit 0
