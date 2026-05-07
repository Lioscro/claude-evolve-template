#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$HOME/.claude/evolve/scripts/lib.sh"

# This is a user-facing admin script (called from approve-global-proposal.sh
# and promote.sh), not a hook entrypoint. We rely on `set -euo pipefail` to
# propagate errors to the caller so failures surface via the caller's `||`
# check. Do NOT add `trap evolve_trap ERR` here — it would silently exit 0
# and hide legitimate failures.
#
# When invoked with --no-lock, the caller (approve-global-proposal.sh)
# holds the global lock on fd 9; the lock is preserved across this fork
# via OFD sharing. This script must skip its own GLOBAL_LOCK
# acquire/release to avoid wedging fd 9. Per-project locks (PROJECT_LOCK)
# are still acquired normally — those use fd 9 too, but reassigning fd 9
# via exec 9>$PROJECT_LOCK in this child does not release the parent's
# global lock (different OFDs).

# ── Arguments ────────────────────────────────────────────────────────────
NO_LOCK=0
if [[ "${1:-}" == "--no-lock" ]]; then
  NO_LOCK=1
  shift
fi
INSTINCT_DATA_FILE="${1:?promote-instinct.sh requires instinct data file path as \$1}"

if [[ ! -f "$INSTINCT_DATA_FILE" ]]; then
  evolve_log "promote-instinct.sh: instinct data file not found: $INSTINCT_DATA_FILE"
  echo "ERROR: instinct data file not found: $INSTINCT_DATA_FILE" >&2
  exit 1
fi

# ── Check global dir exists ─────────────────────────────────────────────
if [[ ! -d "$GLOBAL_DIR" ]]; then
  evolve_log "promote-instinct.sh: global dir does not exist, exiting"
  exit 0
fi

# ── Paths ────────────────────────────────────────────────────────────────
GLOBAL_INSTINCT_DIR="$GLOBAL_DIR/instincts"
GLOBAL_INSTINCT_INDEX="$GLOBAL_INSTINCT_DIR/index.yaml"
GLOBAL_LOCK="$GLOBAL_DIR/global.lock"

# ── Read config ──────────────────────────────────────────────────────────
GLOBAL_INITIAL_CONFIDENCE=$(read_config '.global_instincts.initial_confidence // 0.5' 2>/dev/null || echo "0.5")
GLOBAL_INITIAL_CONFIDENCE=$(validate_numeric "$GLOBAL_INITIAL_CONFIDENCE" "$_NUMERIC_NONNEG_FLOAT" "0.5")
MIN_GROUPING_SIZE=$(read_config '.clustering.min_grouping_size // 2' 2>/dev/null || echo "2")
MIN_GROUPING_SIZE=$(validate_numeric "$MIN_GROUPING_SIZE" "$_NUMERIC_NONNEG_INT" "2")

# ── Parse instinct data ─────────────────────────────────────────────────
INST_ID=$(yq '.id // ""' "$INSTINCT_DATA_FILE" 2>/dev/null || echo "")
INST_TRIGGER=$(yq '.trigger // ""' "$INSTINCT_DATA_FILE" 2>/dev/null || echo "")
INST_ACTION=$(yq '.action // ""' "$INSTINCT_DATA_FILE" 2>/dev/null || echo "")
INST_DOMAIN=$(yq '.domain // "unknown"' "$INSTINCT_DATA_FILE" 2>/dev/null || echo "unknown")

if [[ -z "$INST_ID" ]]; then
  evolve_log "promote-instinct.sh: no id in instinct data, exiting"
  exit 0
fi

# Validate identifiers BEFORE consumption (R5). Fail-fast with exit 1 so the
# caller (approve-global-proposal.sh / promote.sh) sees a non-zero exit code.
if ! validate_id "$INST_ID"; then
  evolve_log "ERROR promote-instinct.sh: invalid identifier id='$INST_ID'"
  exit 1
fi
if ! validate_id "$INST_DOMAIN"; then
  evolve_log "ERROR promote-instinct.sh: invalid identifier domain='$INST_DOMAIN'"
  exit 1
fi

GLOBAL_INST_ID="global-${INST_ID}"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── Read source project instincts ───────────────────────────────────────
SPI_COUNT=$(yq '.source_project_instincts | length' "$INSTINCT_DATA_FILE" 2>/dev/null || echo "0")

# Build source_projects list and source_project_instincts YAML
SRC_PROJECTS_YAML=""
SPI_YAML=""
SEEN_PROJECTS=""
TOTAL_OBS_COUNT=0

for ((i=0; i<SPI_COUNT; i++)); do
  proj=$(yq ".source_project_instincts[$i].project" "$INSTINCT_DATA_FILE" 2>/dev/null || echo "")
  inst=$(yq ".source_project_instincts[$i].instinct" "$INSTINCT_DATA_FILE" 2>/dev/null || echo "")
  if ! validate_id "$proj"; then
    evolve_log "ERROR promote-instinct.sh: invalid identifier source_project_instincts[$i].project='$proj'"
    exit 1
  fi
  if ! validate_id "$inst"; then
    evolve_log "ERROR promote-instinct.sh: invalid identifier source_project_instincts[$i].instinct='$inst'"
    exit 1
  fi
  SPI_YAML+="  - project: $proj"$'\n'
  SPI_YAML+="    instinct: $inst"$'\n'

  if ! echo "$SEEN_PROJECTS" | grep -qx "$proj"; then
    SRC_PROJECTS_YAML+="  - $proj"$'\n'
    SEEN_PROJECTS+="$proj"$'\n'
  fi

  # Sum observation counts from source instincts
  src_inst_file="$EVOLVE_DIR/projects/$proj/instincts/${inst}.yaml"
  if [[ -f "$src_inst_file" ]]; then
    obs_count=$(yq '.observation_count // 0' "$src_inst_file" 2>/dev/null || echo "0")
    TOTAL_OBS_COUNT=$((TOTAL_OBS_COUNT + obs_count))
  fi
done

# ── Step 1: Acquire global lock, create global instinct ──────────────────
# When --no-lock is set, the caller already holds the global lock; skip
# acquisition (and the matching release below) to avoid wedging fd 9.
if [[ "$NO_LOCK" != "1" ]]; then
  if ! acquire_lock "$GLOBAL_LOCK"; then
    evolve_log "promote-instinct.sh: global lock held, exiting"
    exit 0
  fi
fi

# Check if global instinct already exists (idempotency)
if [[ -f "$GLOBAL_INSTINCT_DIR/${GLOBAL_INST_ID}.yaml" ]]; then
  evolve_log "promote-instinct.sh: global instinct $GLOBAL_INST_ID already exists, skipping creation"
else
  # Trigger/action originate from agent output; escape for YAML.
  INST_TRIGGER_ESC=$(yaml_escape_dq "$INST_TRIGGER")
  INST_ACTION_ESC=$(yaml_escape_dq "$INST_ACTION")

  # Write global instinct YAML
  cat > "$GLOBAL_INSTINCT_DIR/${GLOBAL_INST_ID}.yaml" <<ENDYAML
version: 1
id: ${GLOBAL_INST_ID}
trigger: "${INST_TRIGGER_ESC}"
action: "${INST_ACTION_ESC}"
confidence: ${GLOBAL_INITIAL_CONFIDENCE}
domain: ${INST_DOMAIN}
created: "${NOW}"
last_reinforced: "${NOW}"
observation_count: ${TOTAL_OBS_COUNT}
source_projects:
${SRC_PROJECTS_YAML}source_project_instincts:
${SPI_YAML}
ENDYAML

  # Add to global instinct index (atomic write)
  tmp_index=$(mktemp)
  yq ".instincts += [{
    \"id\": \"${GLOBAL_INST_ID}\",
    \"domain\": \"${INST_DOMAIN}\",
    \"confidence\": ${GLOBAL_INITIAL_CONFIDENCE},
    \"trigger\": \"${INST_TRIGGER_ESC}\",
    \"file\": \"${GLOBAL_INST_ID}.yaml\",
    \"source_projects\": [$(echo "$SEEN_PROJECTS" | grep . | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')]
  }]" "$GLOBAL_INSTINCT_INDEX" > "$tmp_index"
  mv "$tmp_index" "$GLOBAL_INSTINCT_INDEX"

  evolve_log "promote-instinct.sh: created global instinct $GLOBAL_INST_ID"
fi

# ── Release global lock ─────────────────────────────────────────────────
# Only release if we acquired it (skip when caller holds the lock).
[[ "$NO_LOCK" != "1" ]] && release_lock "$GLOBAL_LOCK"

# ── Step 2: Archive source project instincts ─────────────────────────────
for ((i=0; i<SPI_COUNT; i++)); do
  proj=$(yq ".source_project_instincts[$i].project" "$INSTINCT_DATA_FILE" 2>/dev/null || echo "")
  inst=$(yq ".source_project_instincts[$i].instinct" "$INSTINCT_DATA_FILE" 2>/dev/null || echo "")

  PROJECT_DIR="$EVOLVE_DIR/projects/$proj"
  PROJECT_LOCK="$PROJECT_DIR/evolve.lock"
  INSTINCTS_DIR="$PROJECT_DIR/instincts"
  INSTINCT_INDEX="$INSTINCTS_DIR/index.yaml"
  INSTINCT_ARCHIVED_DIR="$INSTINCTS_DIR/archived"
  INSTINCT_ARCHIVED_INDEX="$INSTINCT_ARCHIVED_DIR/index.yaml"
  INSTINCT_FILE="$INSTINCTS_DIR/${inst}.yaml"

  # Acquire per-project lock (non-blocking: skip if held)
  if ! acquire_lock "$PROJECT_LOCK"; then
    evolve_log "promote-instinct.sh: project lock held for $proj, skipping instinct $inst"
    continue
  fi

  ARCHIVED_FILE="$INSTINCT_ARCHIVED_DIR/${inst}.yaml"

  # Recovery check: if INSTINCT_FILE is missing but already archived by THIS
  # global promotion, skip the strip-from-SPI branch (the source is legitimately
  # part of this global, just already moved by a prior partial-failure run).
  if [[ ! -f "$INSTINCT_FILE" && -f "$ARCHIVED_FILE" ]]; then
    ARCHIVED_BY=$(yq '.archived_by // ""' "$ARCHIVED_FILE")
    if [[ "$ARCHIVED_BY" == "$GLOBAL_INST_ID" ]]; then
      # Recovery path: this run already archived this source. Optionally repair
      # the archived index entry if it's missing (mirroring approve-proposal.sh).
      ARCHIVED_INDEX_HAS=$(yq ".instincts[] | select(.id == \"${inst}\") | .id" "$INSTINCT_ARCHIVED_INDEX" 2>/dev/null || true)
      if [[ -z "$ARCHIVED_INDEX_HAS" ]]; then
        evolve_log "INFO promote-instinct.sh: archived index missing entry for $inst; repairing"
        ARCHIVED_DOMAIN=$(yq '.domain // "unknown"' "$ARCHIVED_FILE" 2>/dev/null || echo "unknown")
        # archived_at fallback to NOW: cosmetic last-resort. The actual file move
        # happened at the prior run's NOW, but if the archived YAML lacks the
        # field (e.g., older format or hand-edit), reusing today's NOW is the
        # least-wrong option (mirrors approve-proposal.sh:193-195).
        ARCHIVED_AT=$(yq '.archived_at // ""' "$ARCHIVED_FILE" 2>/dev/null || echo "")
        [[ -z "$ARCHIVED_AT" ]] && ARCHIVED_AT="$NOW"
        tmp_arch=$(mktemp)
        yq ".instincts += [{
          \"id\": \"${inst}\",
          \"domain\": \"${ARCHIVED_DOMAIN}\",
          \"archived_reason\": \"promoted_to_global\",
          \"archived_by\": \"${GLOBAL_INST_ID}\",
          \"archived_at\": \"${ARCHIVED_AT}\",
          \"file\": \"${inst}.yaml\"
        }]" "$INSTINCT_ARCHIVED_INDEX" > "$tmp_arch"
        mv "$tmp_arch" "$INSTINCT_ARCHIVED_INDEX"
      else
        evolve_log "INFO promote-instinct.sh: instinct $inst already archived by this global ($GLOBAL_INST_ID)"
      fi
      # Repair live INSTINCT_INDEX if it still has a stale entry -- this happens
      # when a prior run crashed between the file-move (line 217) and the live-
      # index strip (line 222) of the original happy path. Round-1 reviewer
      # Issue 2 closure.
      LIVE_INDEX_HAS=$(yq ".instincts[] | select(.id == \"${inst}\") | .id" "$INSTINCT_INDEX" 2>/dev/null || true)
      if [[ -n "$LIVE_INDEX_HAS" ]]; then
        evolve_log "INFO promote-instinct.sh: live index has stale entry for $inst; pruning"
        tmp_idx=$(mktemp)
        yq ".instincts = [.instincts[] | select(.id != \"${inst}\")]" "$INSTINCT_INDEX" > "$tmp_idx"
        mv "$tmp_idx" "$INSTINCT_INDEX"
      fi
      release_lock "$PROJECT_LOCK"
      continue
    else
      # Archived by a different global promotion. Do NOT strip from this run's
      # SPI -- stripping would corrupt this run's provenance. Log and skip.
      evolve_log "WARN promote-instinct.sh: instinct $inst archived by different proposal '$ARCHIVED_BY' -- skipping (manual intervention required)"
      release_lock "$PROJECT_LOCK"
      continue
    fi
  fi

  # Genuinely missing (not in live, not in archived). Existing strip-from-SPI
  # behavior is correct: agent likely hallucinated this SPI entry.
  if [[ ! -f "$INSTINCT_FILE" ]]; then
    evolve_log "promote-instinct.sh: instinct $inst not found in project $proj, skipping (stripping from global SPI)"
    release_lock "$PROJECT_LOCK"
    if [[ "$NO_LOCK" == "1" ]] || acquire_lock "$GLOBAL_LOCK"; then
      gi_path="$GLOBAL_INSTINCT_DIR/${GLOBAL_INST_ID}.yaml"
      if [[ -f "$gi_path" ]]; then
        tmp_gi=$(mktemp)
        yq ".source_project_instincts = [.source_project_instincts[] | select(.project != \"${proj}\" or .instinct != \"${inst}\")]" "$gi_path" > "$tmp_gi"
        mv "$tmp_gi" "$gi_path"
      fi
      [[ "$NO_LOCK" != "1" ]] && release_lock "$GLOBAL_LOCK"
    fi
    continue
  fi

  # Read domain from instinct
  INSTINCT_DOMAIN=$(yq '.domain // "unknown"' "$INSTINCT_FILE" 2>/dev/null || echo "unknown")

  # Add archival metadata to instinct file
  tmp_inst=$(mktemp)
  yq "
    .archived_reason = \"promoted_to_global\" |
    .archived_by = \"${GLOBAL_INST_ID}\" |
    .archived_at = \"${NOW}\"
  " "$INSTINCT_FILE" > "$tmp_inst"

  # Move instinct file to archived/
  mv "$tmp_inst" "$INSTINCT_ARCHIVED_DIR/${inst}.yaml"
  rm -f "$INSTINCT_FILE"

  # Remove from instincts/index.yaml (atomic write)
  tmp_idx=$(mktemp)
  yq ".instincts = [.instincts[] | select(.id != \"${inst}\")]" "$INSTINCT_INDEX" > "$tmp_idx"
  mv "$tmp_idx" "$INSTINCT_INDEX"

  # Add to instincts/archived/index.yaml (atomic write)
  tmp_arch=$(mktemp)
  yq ".instincts += [{
    \"id\": \"${inst}\",
    \"domain\": \"${INSTINCT_DOMAIN}\",
    \"archived_reason\": \"promoted_to_global\",
    \"archived_by\": \"${GLOBAL_INST_ID}\",
    \"archived_at\": \"${NOW}\",
    \"file\": \"${inst}.yaml\"
  }]" "$INSTINCT_ARCHIVED_INDEX" > "$tmp_arch"
  mv "$tmp_arch" "$INSTINCT_ARCHIVED_INDEX"

  evolve_log "promote-instinct.sh: archived instinct $inst in project $proj"

  # ── Clean up pending project proposals referencing this instinct ────────
  PROPOSALS_DIR="$PROJECT_DIR/proposals"
  PROPOSAL_INDEX="$PROPOSALS_DIR/index.yaml"
  PROPOSAL_ARCHIVED_DIR="$PROPOSALS_DIR/archived"
  PROPOSAL_ARCHIVED_INDEX="$PROPOSAL_ARCHIVED_DIR/index.yaml"

  if [[ -f "$PROPOSAL_INDEX" ]]; then
    prop_count=$(yq '.proposals | length' "$PROPOSAL_INDEX" 2>/dev/null || echo "0")

    # Iterate in reverse so index deletions don't shift
    for ((pi=prop_count-1; pi>=0; pi--)); do
      prop_status=$(yq ".proposals[$pi].status // \"\"" "$PROPOSAL_INDEX" 2>/dev/null || echo "")
      if [[ "$prop_status" != "pending" ]]; then
        continue
      fi

      prop_file=$(yq ".proposals[$pi].file" "$PROPOSAL_INDEX")
      prop_path="$PROPOSALS_DIR/$prop_file"
      if [[ ! -f "$prop_path" ]]; then
        continue
      fi

      # Check if this proposal references the archived instinct
      has_instinct=$(yq "[.source_instincts[] | select(. == \"${inst}\")] | length" "$prop_path" 2>/dev/null || echo "0")
      if [[ "$has_instinct" -eq 0 ]]; then
        continue
      fi

      # Remove the instinct from proposal's source_instincts
      tmp_prop=$(mktemp)
      yq ".source_instincts = [.source_instincts[] | select(. != \"${inst}\")] | .source_instinct_count = (.source_instincts | length)" "$prop_path" > "$tmp_prop"
      mv "$tmp_prop" "$prop_path"

      # Check if proposal dropped below min_grouping_size
      remaining=$(yq '.source_instincts | length' "$prop_path" 2>/dev/null || echo "0")
      if [[ "$remaining" -lt "$MIN_GROUPING_SIZE" ]]; then
        prop_id=$(yq '.id // ""' "$prop_path" 2>/dev/null || echo "")
        evolve_log "promote-instinct.sh: archiving proposal $prop_id (below min_grouping_size after instinct $inst removed)"

        # Archive the proposal
        tmp_prop=$(mktemp)
        yq "
          .status = \"archived\" |
          .archived_reason = \"instinct_promoted\" |
          .archived_at = \"${NOW}\"
        " "$prop_path" > "$tmp_prop"
        mv "$tmp_prop" "$PROPOSAL_ARCHIVED_DIR/$prop_file"
        rm -f "$prop_path"

        # Read metadata for archived index entry
        prop_type=$(yq '.type // ""' "$PROPOSAL_ARCHIVED_DIR/$prop_file" 2>/dev/null || echo "")
        prop_domain=$(yq '.domain // "unknown"' "$PROPOSAL_ARCHIVED_DIR/$prop_file" 2>/dev/null || echo "unknown")
        src_count=$(yq '.source_instincts | length' "$PROPOSAL_ARCHIVED_DIR/$prop_file" 2>/dev/null || echo "0")
        src_yaml=""
        for ((si=0; si<src_count; si++)); do
          sid=$(yq ".source_instincts[$si]" "$PROPOSAL_ARCHIVED_DIR/$prop_file")
          src_yaml+="\"${sid}\", "
        done
        src_yaml="${src_yaml%, }"

        # Remove from proposals/index.yaml
        tmp_idx=$(mktemp)
        yq "del(.proposals[$pi])" "$PROPOSAL_INDEX" > "$tmp_idx"
        mv "$tmp_idx" "$PROPOSAL_INDEX"

        # Add to proposals/archived/index.yaml
        tmp_arch=$(mktemp)
        yq ".proposals += [{
          \"id\": \"${prop_id}\",
          \"type\": \"${prop_type}\",
          \"domain\": \"${prop_domain}\",
          \"status\": \"archived\",
          \"archived_reason\": \"instinct_promoted\",
          \"archived_at\": \"${NOW}\",
          \"source_instincts\": [${src_yaml}],
          \"source_instinct_count\": ${src_count},
          \"file\": \"${prop_file}\"
        }]" "$PROPOSAL_ARCHIVED_INDEX" > "$tmp_arch"
        mv "$tmp_arch" "$PROPOSAL_ARCHIVED_INDEX"
      fi
    done
  fi

  # Release per-project lock
  release_lock "$PROJECT_LOCK"
done

evolve_log "promote-instinct.sh: done (global instinct $GLOBAL_INST_ID)"
exit 0
