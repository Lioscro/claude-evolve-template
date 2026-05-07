#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$HOME/.claude/evolve/scripts/lib.sh"

# Log errors to evolve.log without swallowing exit code -- admin scripts must surface failures.
trap 'evolve_log "ERROR ${BASH_SOURCE[0]##*/}:$LINENO (exit $?)"' ERR

# ── Step 1: Argument validation ──────────────────────────────────────────
if [[ $# -ne 4 ]]; then
  echo "Usage: approve-proposal.sh PROJECT_ID PROPOSAL_ID PROJECT_ROOT CONTENT_FILE" >&2
  exit 1
fi
PROJECT_ID="$1"
PROPOSAL_ID="$2"
PROJECT_ROOT="$3"
CONTENT_FILE="$4"

# Validate PROPOSAL_ID -- it flows into yq query strings throughout this script.
# (PROP_NAME is also validated below, but it's derived from PROPOSAL_ID via sed
# stripping, so a malformed PROPOSAL_ID could pass the PROP_NAME check after
# sanitization. Validate the source.)
if ! validate_id "$PROPOSAL_ID"; then
  echo "ERROR: invalid PROPOSAL_ID (must match $_EVOLVE_ID_REGEX): $PROPOSAL_ID" >&2
  exit 1
fi

# Reject relative content_file paths -- artifact write expects an absolute path.
if [[ "$CONTENT_FILE" != /* ]]; then
  echo "ERROR: CONTENT_FILE must be an absolute path: $CONTENT_FILE" >&2
  exit 1
fi
if [[ ! -f "$CONTENT_FILE" || ! -r "$CONTENT_FILE" ]]; then
  echo "ERROR: CONTENT_FILE not readable: $CONTENT_FILE" >&2
  exit 1
fi

# ── Step 2: Init project + paths ─────────────────────────────────────────
init_project "$PROJECT_ID"

PROJECT_DIR="$EVOLVE_DIR/projects/$PROJECT_ID"
INSTINCTS_DIR="$PROJECT_DIR/instincts"
INSTINCT_INDEX="$INSTINCTS_DIR/index.yaml"
INSTINCT_ARCHIVED_DIR="$INSTINCTS_DIR/archived"
INSTINCT_ARCHIVED_INDEX="$INSTINCT_ARCHIVED_DIR/index.yaml"
PROPOSALS_DIR="$PROJECT_DIR/proposals"
PROPOSAL_INDEX="$PROPOSALS_DIR/index.yaml"
PROPOSAL_ARCHIVED_DIR="$PROPOSALS_DIR/archived"
PROPOSAL_ARCHIVED_INDEX="$PROPOSAL_ARCHIVED_DIR/index.yaml"
LOCK_FILE="$PROJECT_DIR/evolve.lock"

# ── Acquire lock (approval needs the lock -- exit with error if held) ─────
if ! acquire_lock "$LOCK_FILE"; then
  evolve_log "approve-proposal.sh: lock held, cannot proceed"
  echo "ERROR: lock is held by another process. Try again shortly." >&2
  exit 1
fi
trap 'release_lock "$LOCK_FILE"' EXIT

# ── Step 3: Find proposal -- LIVE first, then ARCHIVED fallback (R16) ────
PROPOSAL_FILE=""
PROPOSAL_COUNT=$(yq '.proposals | length' "$PROPOSAL_INDEX" 2>/dev/null || echo "0")
for ((i=0; i<PROPOSAL_COUNT; i++)); do
  pid=$(yq ".proposals[$i].id" "$PROPOSAL_INDEX")
  if [[ "$pid" == "$PROPOSAL_ID" ]]; then
    PROPOSAL_FILE=$(yq ".proposals[$i].file" "$PROPOSAL_INDEX")
    break
  fi
done

IS_RECOVERY=0
SOURCE_PROPOSAL_PATH=""
if [[ -n "$PROPOSAL_FILE" ]]; then
  SOURCE_PROPOSAL_PATH="$PROPOSALS_DIR/$PROPOSAL_FILE"
  if [[ ! -f "$SOURCE_PROPOSAL_PATH" ]]; then
    evolve_log "approve-proposal.sh: live index references missing file $SOURCE_PROPOSAL_PATH"
    echo "ERROR: proposal file $SOURCE_PROPOSAL_PATH does not exist" >&2
    exit 1
  fi
else
  # R16: fall back to archived index for recovery from prior partial-failure
  ARCHIVED_PROPOSAL_COUNT=$(yq '.proposals | length' "$PROPOSAL_ARCHIVED_INDEX" 2>/dev/null || echo "0")
  for ((i=0; i<ARCHIVED_PROPOSAL_COUNT; i++)); do
    pid=$(yq ".proposals[$i].id" "$PROPOSAL_ARCHIVED_INDEX")
    if [[ "$pid" == "$PROPOSAL_ID" ]]; then
      PROPOSAL_FILE=$(yq ".proposals[$i].file" "$PROPOSAL_ARCHIVED_INDEX")
      break
    fi
  done
  if [[ -n "$PROPOSAL_FILE" && -f "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE" ]]; then
    IS_RECOVERY=1
    SOURCE_PROPOSAL_PATH="$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE"
    evolve_log "INFO approve-proposal.sh: recovery mode -- proposal $PROPOSAL_ID found in archived index"
  else
    evolve_log "approve-proposal.sh: proposal $PROPOSAL_ID not found in live or archived index"
    echo "ERROR: proposal $PROPOSAL_ID not found in live or archived index" >&2
    exit 1
  fi
fi

# ── Step 4: Read proposal metadata ───────────────────────────────────────
PROP_TYPE=$(yq '.type // ""' "$SOURCE_PROPOSAL_PATH")
PROP_NAME=$(yq '.id // ""' "$SOURCE_PROPOSAL_PATH" | sed 's/^proposal-//; s/-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}$//')
if ! validate_id "$PROP_NAME"; then
  echo "ERROR: invalid PROP_NAME derived from proposal id (must match $_EVOLVE_ID_REGEX)" >&2
  exit 1
fi
SRC_COUNT=$(yq '.source_instincts | length' "$SOURCE_PROPOSAL_PATH" 2>/dev/null || echo "0")
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Read source_instincts ONCE into a bash array (used by both archive-loop and archived-index-entry build)
SRC_IDS=()
for ((i=0; i<SRC_COUNT; i++)); do
  SRC_IDS+=("$(yq ".source_instincts[$i]" "$SOURCE_PROPOSAL_PATH")")
done

# ── Step 5: Compute artifact destination + write artifact ────────────────
# (Mirror write-artifact.sh:24-43 case logic so we can detect existing artifact for recovery.)
DEST=""
case "$PROP_TYPE" in
  skill)
    DEST="$PROJECT_ROOT/.claude/skills/evolve-${PROP_NAME}.md"
    ;;
  rule)
    DEST="$PROJECT_ROOT/.claude/rules/evolve-${PROP_NAME}.md"
    ;;
  memory)
    DEST="$EVOLVE_DIR/projects/${PROJECT_ID}/memory/${PROP_NAME}.md"
    ;;
  *)
    echo "ERROR: unknown artifact type '$PROP_TYPE' (expected skill, rule, or memory)" >&2
    exit 1
    ;;
esac

if [[ $IS_RECOVERY -eq 1 && -f "$DEST" ]]; then
  evolve_log "INFO approve-proposal.sh: recovery mode -- artifact already at $DEST, skipping write"
else
  # Suppress write-artifact.sh's stdout (DEST path) -- our stdout contract is "<type> <name>" only.
  "$EVOLVE_DIR/scripts/write-artifact.sh" "$PROJECT_ROOT" "$PROP_TYPE" "$PROP_NAME" "$CONTENT_FILE" "$PROJECT_ID" >/dev/null
fi

# ── Step 5b: Append memory index entry (top-level; idempotent on recovery) ──
if [[ "$PROP_TYPE" == "memory" ]]; then
  MEMORY_INDEX="$EVOLVE_DIR/projects/$PROJECT_ID/memory/index.yaml"
  # MEMORY_INDEX is guaranteed to exist because init_project (above) created it.
  EXISTING_ENTRY=$(yq ".memories[] | select(.id == \"${PROPOSAL_ID}\") | .id" "$MEMORY_INDEX" 2>/dev/null || true)
  if [[ -z "$EXISTING_ENTRY" ]]; then
    PROP_TITLE_ESC=$(yaml_escape_dq "$(yq '.title // ""' "$SOURCE_PROPOSAL_PATH")")
    PROP_DESC_ESC=$(yaml_escape_dq "$(yq '.description // ""' "$SOURCE_PROPOSAL_PATH")")
    tmp_midx=$(mktemp)
    yq ".memories += [{
      \"id\": \"${PROPOSAL_ID}\",
      \"file\": \"${PROP_NAME}.md\",
      \"title\": \"${PROP_TITLE_ESC}\",
      \"description\": \"${PROP_DESC_ESC}\",
      \"source_proposal\": \"${PROPOSAL_ID}\",
      \"created\": \"${NOW}\"
    }]" "$MEMORY_INDEX" > "$tmp_midx"
    mv "$tmp_midx" "$MEMORY_INDEX"
  fi
fi

# ── Step 6-10: Archive proposal (skip if recovery; already archived) ─────
if [[ $IS_RECOVERY -eq 0 ]]; then
  # Update proposal status
  tmp_prop=$(mktemp)
  yq "
    .status = \"approved\" |
    .resolved_at = \"${NOW}\"
  " "$SOURCE_PROPOSAL_PATH" > "$tmp_prop"

  # Move to archived/
  mv "$tmp_prop" "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE"
  rm -f "$SOURCE_PROPOSAL_PATH"

  # Remove from live proposals/index.yaml (rewrite pattern)
  tmp_idx=$(mktemp)
  yq ".proposals = [.proposals[] | select(.id != \"${PROPOSAL_ID}\")]" "$PROPOSAL_INDEX" > "$tmp_idx"
  mv "$tmp_idx" "$PROPOSAL_INDEX"

  # Append to archived proposals index
  PROP_DOMAIN=$(yq '.domain // "unknown"' "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE" 2>/dev/null || echo "unknown")
  SRC_INSTINCT_YAML=""
  # Guarded array expansion -- bash 3.2 + set -u trips on "${SRC_IDS[@]}" when array is empty.
  for src_id in ${SRC_IDS[@]+"${SRC_IDS[@]}"}; do
    SRC_INSTINCT_YAML+="\"${src_id}\", "
  done
  SRC_INSTINCT_YAML="${SRC_INSTINCT_YAML%, }"

  tmp_arch=$(mktemp)
  yq ".proposals += [{
    \"id\": \"${PROPOSAL_ID}\",
    \"type\": \"${PROP_TYPE}\",
    \"domain\": \"${PROP_DOMAIN}\",
    \"status\": \"approved\",
    \"resolved_at\": \"${NOW}\",
    \"source_instincts\": [${SRC_INSTINCT_YAML}],
    \"source_instinct_count\": ${SRC_COUNT},
    \"file\": \"${PROPOSAL_FILE}\"
  }]" "$PROPOSAL_ARCHIVED_INDEX" > "$tmp_arch"
  mv "$tmp_arch" "$PROPOSAL_ARCHIVED_INDEX"
fi

# ── Step 11: Archive each source instinct (idempotent) ───────────────────
# Guarded array expansion -- bash 3.2 + set -u trips on "${SRC_IDS[@]}" when array is empty.
for INSTINCT_ID in ${SRC_IDS[@]+"${SRC_IDS[@]}"}; do
  INSTINCT_FILE="$INSTINCTS_DIR/${INSTINCT_ID}.yaml"
  ARCHIVED_FILE="$INSTINCT_ARCHIVED_DIR/${INSTINCT_ID}.yaml"

  if [[ ! -f "$INSTINCT_FILE" && -f "$ARCHIVED_FILE" ]]; then
    # Already archived -- check archived_by matches (R16 idempotent re-run)
    ARCHIVED_BY=$(yq '.archived_by // ""' "$ARCHIVED_FILE")
    if [[ "$ARCHIVED_BY" == "$PROPOSAL_ID" ]]; then
      # Check INSTINCT_ARCHIVED_INDEX has this id; if missing, partial-failure
      # left the index stale -- repair it.
      ARCHIVED_INDEX_HAS=$(yq ".instincts[] | select(.id == \"${INSTINCT_ID}\") | .id" "$INSTINCT_ARCHIVED_INDEX" 2>/dev/null || true)
      if [[ -z "$ARCHIVED_INDEX_HAS" ]]; then
        evolve_log "INFO approve-proposal.sh: archived index missing entry for $INSTINCT_ID; repairing"
        ARCHIVED_DOMAIN=$(yq '.domain // "unknown"' "$ARCHIVED_FILE" 2>/dev/null || echo "unknown")
        ARCHIVED_AT=$(yq '.archived_at // ""' "$ARCHIVED_FILE" 2>/dev/null || echo "")
        if [[ -z "$ARCHIVED_AT" ]]; then
          ARCHIVED_AT="$NOW"
        fi
        tmp_arch=$(mktemp)
        yq ".instincts += [{
          \"id\": \"${INSTINCT_ID}\",
          \"domain\": \"${ARCHIVED_DOMAIN}\",
          \"archived_reason\": \"proposal_approved\",
          \"archived_by\": \"${PROPOSAL_ID}\",
          \"archived_at\": \"${ARCHIVED_AT}\",
          \"file\": \"${INSTINCT_ID}.yaml\"
        }]" "$INSTINCT_ARCHIVED_INDEX" > "$tmp_arch"
        mv "$tmp_arch" "$INSTINCT_ARCHIVED_INDEX"
      else
        evolve_log "INFO approve-proposal.sh: instinct $INSTINCT_ID already archived by this proposal"
      fi
      continue
    else
      evolve_log "WARN approve-proposal.sh: instinct $INSTINCT_ID archived by different proposal '$ARCHIVED_BY' -- skipping (manual intervention required)"
      continue
    fi
  fi

  if [[ ! -f "$INSTINCT_FILE" ]]; then
    evolve_log "WARN approve-proposal.sh: source instinct $INSTINCT_ID missing (not in live, not in archived)"
    continue
  fi

  # Read domain from instinct
  INSTINCT_DOMAIN=$(yq '.domain // "unknown"' "$INSTINCT_FILE" 2>/dev/null || echo "unknown")

  # Add archival metadata to instinct file
  tmp_inst=$(mktemp)
  yq "
    .archived_reason = \"proposal_approved\" |
    .archived_by = \"${PROPOSAL_ID}\" |
    .archived_at = \"${NOW}\"
  " "$INSTINCT_FILE" > "$tmp_inst"

  # Move instinct file to archived/
  mv "$tmp_inst" "$ARCHIVED_FILE"
  rm -f "$INSTINCT_FILE"

  # Remove from live instincts/index.yaml (rewrite pattern, atomic)
  tmp_idx=$(mktemp)
  yq ".instincts = [.instincts[] | select(.id != \"${INSTINCT_ID}\")]" "$INSTINCT_INDEX" > "$tmp_idx"
  mv "$tmp_idx" "$INSTINCT_INDEX"

  # Append to archived instincts index (atomic)
  tmp_arch=$(mktemp)
  yq ".instincts += [{
    \"id\": \"${INSTINCT_ID}\",
    \"domain\": \"${INSTINCT_DOMAIN}\",
    \"archived_reason\": \"proposal_approved\",
    \"archived_by\": \"${PROPOSAL_ID}\",
    \"archived_at\": \"${NOW}\",
    \"file\": \"${INSTINCT_ID}.yaml\"
  }]" "$INSTINCT_ARCHIVED_INDEX" > "$tmp_arch"
  mv "$tmp_arch" "$INSTINCT_ARCHIVED_INDEX"

  evolve_log "approve-proposal.sh: archived instinct $INSTINCT_ID"
done

# ── Step 12: Release lock + git push (R18 ordering) ──────────────────────
release_lock "$LOCK_FILE"
trap - EXIT

evolve_git_push "evolve(approve): approved ${PROPOSAL_ID} (${SRC_COUNT} instincts archived)"

evolve_log "approve-proposal.sh: approved proposal $PROPOSAL_ID (type=$PROP_TYPE, name=$PROP_NAME)"

# ── Step 13: Stdout contract (R18) -- AFTER lock release and git push ────
echo "$PROP_TYPE $PROP_NAME"
exit 0
