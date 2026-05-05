#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$HOME/.claude/evolve/scripts/lib.sh"

# Trap errors -- log and exit 0 (never block Claude)
trap 'evolve_trap $LINENO $?' ERR

# ── Arguments ──────────────────────────────────────────────────────────────
PROJECT_ID="${1:?observe.sh requires PROJECT_ID as \$1}"

# ── Paths ──────────────────────────────────────────────────────────────────
PROJECT_DIR="$EVOLVE_DIR/projects/$PROJECT_ID"
OBS_DIR="$PROJECT_DIR/observations"
INSTINCTS_DIR="$PROJECT_DIR/instincts"
INDEX_FILE="$INSTINCTS_DIR/index.yaml"
LOCK_FILE="$PROJECT_DIR/evolve.lock"

# ── Acquire lock (exit 0 if held) ─────────────────────────────────────────
if ! acquire_lock "$LOCK_FILE"; then
  evolve_log "observe.sh: lock held, exiting"
  exit 0
fi
trap 'release_lock "$LOCK_FILE"' EXIT

# ── Rotate log ─────────────────────────────────────────────────────────────
rotate_log

# ── Snapshot observation files via atomic rename under writer lock ─────────
# Phase A: rename fresh session.jsonl files under per-file writer lock to a
# unique-suffixed name. Per-run unique suffix prevents collision with stale
# orphans from prior crashed runs. observe.sh holds the project lock (fd 9)
# throughout; the writer lock is on fd 7, so they may be held concurrently.
RUN_ID="$(date -u +%s)-$$"

for f in "$OBS_DIR"/*.jsonl; do
  [[ -f "$f" ]] || continue
  if acquire_writer_lock "${f}.lock" 2; then
    mv "$f" "${f}.processing.${RUN_ID}"
    release_writer_lock "${f}.lock"
  else
    evolve_log "WARN observe.sh: skipping $f (writer lock timeout)"
  fi
done

# Phase B: enumerate ALL .processing.* files (recovers orphans from crashed prior runs).
OBSERVATION_FILES=()
for f in "$OBS_DIR"/*.processing.*; do
  [[ -f "$f" ]] || continue
  OBSERVATION_FILES+=("$f")
done

if [[ ${#OBSERVATION_FILES[@]} -eq 0 ]]; then
  evolve_log "observe.sh: no observation files to process"
  exit 0
fi

evolve_log "observe.sh: found ${#OBSERVATION_FILES[@]} observation file(s)"

# ── Read existing instincts ────────────────────────────────────────────────
INSTINCT_YAML=""
INSTINCT_COUNT=0

if [[ -f "$INDEX_FILE" ]]; then
  INSTINCT_COUNT=$(yq '.instincts | length' "$INDEX_FILE" 2>/dev/null || echo "0")
fi

if [[ "$INSTINCT_COUNT" -gt 0 ]]; then
  # Read each instinct file's full content
  for ((i=0; i<INSTINCT_COUNT; i++)); do
    local_file=$(yq ".instincts[$i].file" "$INDEX_FILE")
    instinct_path="$INSTINCTS_DIR/$local_file"
    if [[ -f "$instinct_path" ]]; then
      INSTINCT_YAML+="$(cat "$instinct_path")"
      INSTINCT_YAML+=$'\n---\n'
    fi
  done
fi

# ── Read config values ─────────────────────────────────────────────────────
MAX_OBS=$(read_config '.observations.max_observations_per_run // 200' "$PROJECT_ID" 2>/dev/null || echo "200")
MAX_OBS=$(validate_numeric "$MAX_OBS" "$_NUMERIC_NONNEG_INT" "200")
INITIAL_CONFIDENCE=$(read_config '.instincts.initial_confidence // 0.3' "$PROJECT_ID" 2>/dev/null || echo "0.3")
INITIAL_CONFIDENCE=$(validate_numeric "$INITIAL_CONFIDENCE" "$_NUMERIC_NONNEG_FLOAT" "0.3")
REINFORCEMENT_INC=$(read_config '.instincts.reinforcement_increment // 0.15' "$PROJECT_ID" 2>/dev/null || echo "0.15")
REINFORCEMENT_INC=$(validate_numeric "$REINFORCEMENT_INC" "$_NUMERIC_NONNEG_FLOAT" "0.15")
MAX_CONFIDENCE=$(read_config '.instincts.max_confidence // 0.95' "$PROJECT_ID" 2>/dev/null || echo "0.95")
MAX_CONFIDENCE=$(validate_numeric "$MAX_CONFIDENCE" "$_NUMERIC_NONNEG_FLOAT" "0.95")
DECAY_PER_RUN=$(read_config '.instincts.decay_per_run // 0.05' "$PROJECT_ID" 2>/dev/null || echo "0.05")
DECAY_PER_RUN=$(validate_numeric "$DECAY_PER_RUN" "$_NUMERIC_NONNEG_FLOAT" "0.05")
DECAY_FLOOR=$(read_config '.instincts.decay_floor // 0.1' "$PROJECT_ID" 2>/dev/null || echo "0.1")
DECAY_FLOOR=$(validate_numeric "$DECAY_FLOOR" "$_NUMERIC_NONNEG_FLOAT" "0.1")

# ── Concatenate observations (with batching) ───────────────────────────────
# Build parallel arrays: ALL_LINES holds line content, LINE_FILE_IDX holds the
# index into OBSERVATION_FILES. Per-line origin tracking enables per-batch
# checkpointing -- after a batch succeeds, we know exactly which lines came
# from which .processing.* file and can rebuild that file with only the
# remainder.
ALL_LINES=()
LINE_FILE_IDX=()
OBS_LINE_COUNT=0
for ((fi=0; fi<${#OBSERVATION_FILES[@]}; fi++)); do
  f="${OBSERVATION_FILES[$fi]}"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ALL_LINES+=("$line")
    LINE_FILE_IDX+=("$fi")
    OBS_LINE_COUNT=$((OBS_LINE_COUNT + 1))
  done < "$f"
done

evolve_log "observe.sh: ${OBS_LINE_COUNT} observation lines to process"

# ── Collect session IDs from observations ──────────────────────────────────
SESSION_IDS=()
for f in "${OBSERVATION_FILES[@]}"; do
  # Files are named <session-id>.jsonl.processing.<run-id>; strip the suffix.
  fname="$(basename "$f")"
  sid="${fname%%.jsonl.processing*}"
  SESSION_IDS+=("$sid")
done

# ── Process observations in batches ────────────────────────────────────────
# Track which instincts were reinforced across all batches (newline-separated string for bash 3.2 compat)
REINFORCED_IDS=""
# Counters for descriptive commit messages (global -- incremented inside inner functions)
CREATED_COUNT=0
OBS_REINFORCED_COUNT=0
DECAYED_COUNT=0
DELETED_COUNT=0

process_batch() {
  local batch_observations="$1"

  # Build agent input
  local agent_input=""
  agent_input+="## Existing Instincts"$'\n'
  if [[ -n "$INSTINCT_YAML" ]]; then
    agent_input+="$INSTINCT_YAML"
  else
    agent_input+="(none)"
  fi
  agent_input+=$'\n\n'
  agent_input+="## New Observations"$'\n'
  agent_input+="$batch_observations"

  # Invoke observer agent
  local agent_output
  agent_output=$(echo "$agent_input" | invoke_agent "$EVOLVE_DIR/agents/observer.md" 2>/dev/null) || {
    evolve_log "observe.sh: agent invocation failed"
    return 1
  }

  # ── Parse agent output ───────────────────────────────────────────────────
  local in_create=0
  local create_id="" create_trigger="" create_action="" create_domain=""
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  finalize_create() {
    if [[ -z "$create_id" ]]; then
      return
    fi

    # Validate agent-emitted identifiers BEFORE any file/yq use (R5).
    # Empty create_domain is rejected here -- partial fix to #49.
    if ! validate_id "$create_id" || ! validate_id "$create_domain"; then
      evolve_log "WARN observe.sh: rejected CREATE block id='$create_id' domain='$create_domain'"
      return
    fi

    # Check for duplicate ID -- treat as REINFORCE instead
    if [[ -f "$INSTINCTS_DIR/${create_id}.yaml" ]]; then
      evolve_log "observe.sh: CREATE $create_id already exists, treating as REINFORCE"
      do_reinforce "$create_id"
    else
      evolve_log "observe.sh: CREATE instinct $create_id"
      CREATED_COUNT=$((CREATED_COUNT + 1))

      # Write instinct file. Trigger and action are agent-emitted free text and
      # may contain quotes/backslashes/newlines; escape for YAML.
      local trigger_esc action_esc
      trigger_esc=$(yaml_escape_dq "$create_trigger")
      action_esc=$(yaml_escape_dq "$create_action")
      cat > "$INSTINCTS_DIR/${create_id}.yaml" <<YAML
version: 1
id: ${create_id}
trigger: "${trigger_esc}"
action: "${action_esc}"
confidence: ${INITIAL_CONFIDENCE}
domain: ${create_domain}
created: "${now}"
last_reinforced: "${now}"
observation_count: 1
source_sessions:
YAML
      # Add session IDs
      for sid in "${SESSION_IDS[@]}"; do
        echo "  - ${sid}" >> "$INSTINCTS_DIR/${create_id}.yaml"
      done

      # Add to index
      local tmp_index
      tmp_index=$(mktemp)
      yq ".instincts += [{
        \"id\": \"${create_id}\",
        \"domain\": \"${create_domain}\",
        \"confidence\": ${INITIAL_CONFIDENCE},
        \"trigger\": \"${trigger_esc}\",
        \"file\": \"${create_id}.yaml\"
      }]" "$INDEX_FILE" > "$tmp_index"
      mv "$tmp_index" "$INDEX_FILE"
    fi

    REINFORCED_IDS+="$create_id"$'\n'
    create_id=""
    create_trigger=""
    create_action=""
    create_domain=""
  }

  do_reinforce() {
    local instinct_id="$1"
    if ! validate_id "$instinct_id"; then
      evolve_log "WARN observe.sh: do_reinforce called with invalid id '$instinct_id'"
      return
    fi
    local instinct_file="$INSTINCTS_DIR/${instinct_id}.yaml"

    if [[ ! -f "$instinct_file" ]]; then
      evolve_log "observe.sh: REINFORCE $instinct_id -- file not found, skipping"
      return
    fi

    if ! yq '.' "$instinct_file" >/dev/null 2>&1; then
      evolve_log "observe.sh: REINFORCE $instinct_id -- malformed YAML, skipping"
      return
    fi

    evolve_log "observe.sh: REINFORCE instinct $instinct_id"
    OBS_REINFORCED_COUNT=$((OBS_REINFORCED_COUNT + 1))

    # Bump confidence (capped at max_confidence)
    local current_conf
    current_conf=$(yq '.confidence // 0' "$instinct_file" 2>/dev/null || echo "0")
    local new_conf
    new_conf=$(bc_calc "$current_conf + $REINFORCEMENT_INC")
    # Cap at max
    if (( $(echo "$new_conf > $MAX_CONFIDENCE" | bc -l) )); then
      new_conf="$MAX_CONFIDENCE"
    fi

    # Increment observation_count
    local current_count
    current_count=$(yq '.observation_count // 0' "$instinct_file" 2>/dev/null || echo "0")
    local new_count=$((current_count + 1))

    # Update instinct file
    local tmp_inst
    tmp_inst=$(mktemp)
    yq "
      .confidence = ${new_conf} |
      .observation_count = ${new_count} |
      .last_reinforced = \"${now}\"
    " "$instinct_file" > "$tmp_inst"

    # Add session IDs (deduplicate)
    for sid in "${SESSION_IDS[@]}"; do
      local has_sid
      has_sid=$(yq "[.source_sessions // [] | .[] | select(. == \"${sid}\")] | length" "$tmp_inst" 2>/dev/null || echo "0")
      if [[ "$has_sid" == "0" ]]; then
        local tmp2
        tmp2=$(mktemp)
        yq ".source_sessions += [\"${sid}\"]" "$tmp_inst" > "$tmp2"
        mv "$tmp2" "$tmp_inst"
      fi
    done

    mv "$tmp_inst" "$instinct_file"

    # Update confidence in index
    local tmp_idx
    tmp_idx=$(mktemp)
    yq "(.instincts[] | select(.id == \"${instinct_id}\")).confidence = ${new_conf}" "$INDEX_FILE" > "$tmp_idx"
    mv "$tmp_idx" "$INDEX_FILE"

    REINFORCED_IDS+="$instinct_id"$'\n'
  }

  # Parse line by line
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Trim whitespace
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Empty line or new directive finalizes any pending CREATE
    if [[ -z "$line" ]] || [[ "$line" =~ ^(REINFORCE|CREATE|SKIP) ]]; then
      if [[ "$in_create" -eq 1 ]]; then
        finalize_create
        in_create=0
      fi
    fi

    # Skip empty lines
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ ^REINFORCE\ (.+)$ ]]; then
      do_reinforce "${BASH_REMATCH[1]}"
    elif [[ "$line" == "CREATE" ]]; then
      in_create=1
      create_id=""
      create_trigger=""
      create_action=""
      create_domain=""
    elif [[ "$in_create" -eq 1 ]]; then
      if [[ "$line" =~ ^id:\ *(.+)$ ]]; then
        create_id="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^trigger:\ *(.+)$ ]]; then
        create_trigger="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^action:\ *(.+)$ ]]; then
        create_action="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^domain:\ *(.+)$ ]]; then
        create_domain="${BASH_REMATCH[1]}"
      fi
    elif [[ "$line" == "SKIP" ]]; then
      : # No action
    fi
  done <<< "$agent_output"

  # Finalize any trailing CREATE block
  if [[ "$in_create" -eq 1 ]]; then
    finalize_create
  fi
}

# Ensure archive dir exists before the batch loop, so checkpoint_batch can
# append archived lines per-batch (R3).
ARCHIVE_DIR="$OBS_DIR/archived"
mkdir -p "$ARCHIVE_DIR"

# checkpoint_batch <start_idx> <end_idx>
# Archive lines ALL_LINES[start..end] and remove them from their .processing files.
# Idempotent within the batch loop: rebuilds .processing files atomically via
# temp + mv so a crash mid-checkpoint leaves either the old or the new content.
#
# INVARIANT (round-1 reviewer HIGH-2): ALL_LINES is built in OBSERVATION_FILES
# order, and within each file we read top-to-bottom. So all lines from file fi
# are CONTIGUOUS in ALL_LINES indices. Once we've checkpointed past the last
# line of file fi, that file is removed and never revisited. Future refactors
# that reorder ALL_LINES (e.g., interleaving for fairness) MUST re-establish
# this invariant or the per-file rebuild logic will silently corrupt files.
#
# DEPENDENCIES (globals): OBSERVATION_FILES, LINE_FILE_IDX, ALL_LINES,
# OBS_LINE_COUNT, ARCHIVE_DIR, OBS_DIR. Lines containing embedded newlines are
# impossible (each ALL_LINES element is one read -r line, no \n inside).
checkpoint_batch() {
  local start=$1 end=$2

  for ((fi=0; fi<${#OBSERVATION_FILES[@]}; fi++)); do
    local pf="${OBSERVATION_FILES[$fi]}"
    [[ -f "$pf" ]] || continue

    local fname sid
    fname="$(basename "$pf")"
    sid="${fname%%.jsonl.processing*}"

    # Append batch-range lines for this file to archive.
    local processed_any=0 bi
    for ((bi=start; bi<=end; bi++)); do
      if [[ "${LINE_FILE_IDX[$bi]}" == "$fi" ]]; then
        printf '%s\n' "${ALL_LINES[$bi]}" >> "$ARCHIVE_DIR/${sid}.jsonl"
        processed_any=1
      fi
    done

    # Skip rebuild if no lines from this batch came from this file.
    [[ $processed_any -eq 0 ]] && continue

    # Rebuild .processing with lines whose index > end (still pending) and whose
    # file index matches.
    local tmp ai
    tmp=$(mktemp)
    for ((ai=end+1; ai<OBS_LINE_COUNT; ai++)); do
      if [[ "${LINE_FILE_IDX[$ai]}" == "$fi" ]]; then
        printf '%s\n' "${ALL_LINES[$ai]}" >> "$tmp"
      fi
    done

    if [[ -s "$tmp" ]]; then
      mv "$tmp" "$pf"
    else
      rm -f "$tmp"
      rm -f "$pf"
      rm -f "$OBS_DIR/${sid}.jsonl.lock"
      rm -rf "$OBS_DIR/${sid}.jsonl.lock.d"
    fi
  done
}

# Drive batches from index ranges into ALL_LINES.
batch_start=0
while [[ $batch_start -lt $OBS_LINE_COUNT ]]; do
  batch_end=$(( batch_start + MAX_OBS - 1 ))
  if [[ $batch_end -ge $OBS_LINE_COUNT ]]; then
    batch_end=$(( OBS_LINE_COUNT - 1 ))
  fi

  # Build batch text from ALL_LINES[batch_start..batch_end].
  batch=""
  for ((bi=batch_start; bi<=batch_end; bi++)); do
    batch+="${ALL_LINES[$bi]}"$'\n'
  done

  batch_num=$(( (batch_start / MAX_OBS) + 1 ))
  evolve_log "observe.sh: processing batch $batch_num ($((batch_end - batch_start + 1)) lines)"
  process_batch "$batch"

  # Checkpoint: archive processed lines, rebuild .processing files. If
  # process_batch failed, the ERR trap fired and we never reach here.
  checkpoint_batch "$batch_start" "$batch_end"

  batch_start=$(( batch_end + 1 ))
done

# ── Apply decay ────────────────────────────────────────────────────────────
# For every instinct NOT reinforced in this run, reduce confidence by decay_per_run.
# Delete instincts that drop below decay_floor.
if [[ -f "$INDEX_FILE" ]]; then
  current_count=$(yq '.instincts | length' "$INDEX_FILE" 2>/dev/null || echo "0")
  # Iterate in reverse so deletions don't shift indexes
  for ((i=current_count-1; i>=0; i--)); do
    inst_id=$(yq ".instincts[$i].id" "$INDEX_FILE")

    # Skip instincts that were reinforced (or created) this run
    if echo "$REINFORCED_IDS" | grep -qx "$inst_id"; then
      continue
    fi

    inst_file="$INSTINCTS_DIR/${inst_id}.yaml"
    if [[ ! -f "$inst_file" ]]; then
      continue
    fi

    current_conf=$(yq '.confidence // 0' "$inst_file")
    new_conf=$(bc_calc "$current_conf - $DECAY_PER_RUN")

    if (( $(echo "$new_conf < $DECAY_FLOOR" | bc -l) )); then
      # Delete instinct
      DELETED_COUNT=$((DELETED_COUNT + 1))
      evolve_log "observe.sh: decayed instinct $inst_id below floor ($new_conf < $DECAY_FLOOR), deleting"
      rm -f "$inst_file"
      tmp_idx=$(mktemp)
      yq "del(.instincts[$i])" "$INDEX_FILE" > "$tmp_idx"
      mv "$tmp_idx" "$INDEX_FILE"
    else
      # Update confidence
      DECAYED_COUNT=$((DECAYED_COUNT + 1))
      tmp_inst=$(mktemp)
      yq ".confidence = ${new_conf}" "$inst_file" > "$tmp_inst"
      mv "$tmp_inst" "$inst_file"
      tmp_idx=$(mktemp)
      yq "(.instincts[] | select(.id == \"${inst_id}\")).confidence = ${new_conf}" "$INDEX_FILE" > "$tmp_idx"
      mv "$tmp_idx" "$INDEX_FILE"
    fi
  done
fi

# ── Write index atomically ─────────────────────────────────────────────────
# Index has been updated in-place above; do a final atomic write for safety
tmp_final=$(mktemp)
cp "$INDEX_FILE" "$tmp_final"
mv "$tmp_final" "$INDEX_FILE"

# ── Archive processed observation files (defensive backstop) ──────────────
# Per-batch checkpointing already archives each batch's lines and rebuilds
# .processing files, so this loop is a no-op for the common case (files
# already removed). It still cleans up edge cases like a session file that
# contained only blank lines (skipped during line collection, never enters
# ALL_LINES, never checkpointed). ARCHIVE_DIR was created before the batch
# loop; no need to mkdir again here.
# Strip the .processing.<run-id> suffix back to .jsonl for the archived name.
# Use append-mode so a same-session-id rerun does not clobber prior archives.
# Best-effort lock-file cleanup; a concurrent writer may recreate the lock,
# which is harmless (the writer will own the new lock and proceed normally).
for f in "${OBSERVATION_FILES[@]}"; do
  [[ -f "$f" ]] || continue
  fname="$(basename "$f")"
  sid="${fname%%.jsonl.processing*}"
  cat "$f" >> "$ARCHIVE_DIR/${sid}.jsonl"
  rm -f "$f"
  rm -f "$OBS_DIR/${sid}.jsonl.lock"
  rm -rf "$OBS_DIR/${sid}.jsonl.lock.d"
done

evolve_log "observe.sh: archived ${#OBSERVATION_FILES[@]} observation file(s)"

# ── Release lock (EXIT trap handles this) ──────────────────────────────────
release_lock "$LOCK_FILE"
trap - EXIT

# ── Trigger clustering (after lock released) ───────────────────────────────
if [[ -x "$EVOLVE_DIR/scripts/cluster.sh" ]]; then
  "$EVOLVE_DIR/scripts/cluster.sh" "$PROJECT_ID" 2>/dev/null || true
fi

# ── Trigger global promotion (after clustering) ──────────────────────────
if [[ -x "$EVOLVE_DIR/scripts/promote.sh" ]]; then
  "$EVOLVE_DIR/scripts/promote.sh" 2>/dev/null || true
fi

# ── Sync to git (after all writes including clustering) ───────────────────
evolve_git_push "evolve(observe): ${CREATED_COUNT} created, ${OBS_REINFORCED_COUNT} reinforced, ${DECAYED_COUNT} decayed, ${DELETED_COUNT} deleted"

evolve_log "observe.sh: done"
exit 0
