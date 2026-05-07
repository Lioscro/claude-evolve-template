#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$HOME/.claude/evolve/scripts/lib.sh"

# Log errors to evolve.log without swallowing exit code -- admin scripts must surface failures.
trap 'evolve_log "ERROR ${BASH_SOURCE[0]##*/}:$LINENO (exit $?)"' ERR

# ── Arguments ──────────────────────────────────────────────────────────────
PROPOSAL_ID="${1:?approve-global-proposal.sh requires PROPOSAL_ID as \$1}"

if ! validate_id "$PROPOSAL_ID"; then
  echo "ERROR: invalid PROPOSAL_ID (must match $_EVOLVE_ID_REGEX): $PROPOSAL_ID" >&2
  exit 1
fi

# ── Check global dir exists ───────────────────────────────────────────────
if [[ ! -d "$GLOBAL_DIR" ]]; then
  evolve_log "approve-global-proposal.sh: global dir does not exist"
  echo "ERROR: global dir does not exist" >&2
  exit 1
fi

# Defensive init: existing users on the upgrade path may not have re-run install.sh.
init_global 2>/dev/null || true

# ── Paths ──────────────────────────────────────────────────────────────────
PROPOSALS_DIR="$GLOBAL_DIR/proposals"
PROPOSAL_INDEX="$PROPOSALS_DIR/index.yaml"
PROPOSAL_ARCHIVED_DIR="$PROPOSALS_DIR/archived"
PROPOSAL_ARCHIVED_INDEX="$PROPOSAL_ARCHIVED_DIR/index.yaml"
GLOBAL_LOCK="$GLOBAL_DIR/global.lock"

# ── Acquire global lock ───────────────────────────────────────────────────
if ! acquire_lock "$GLOBAL_LOCK"; then
  evolve_log "approve-global-proposal.sh: global lock held, cannot proceed"
  echo "ERROR: global lock is held by another process. Try again shortly." >&2
  exit 1
fi
trap 'release_lock "$GLOBAL_LOCK"' EXIT

# ── IS_RECOVERY flag: tracks whether we are recovering from a prior partial run ──
IS_RECOVERY=0
# ── MID_ARCHIVAL flag: proposal in live index but file already at archived path ──
MID_ARCHIVAL=0

# ── Find proposal file via live index ────────────────────────────────────
PROPOSAL_FILE=""
PROPOSAL_COUNT=$(yq '.proposals | length' "$PROPOSAL_INDEX" 2>/dev/null || echo "0")

for ((i=0; i<PROPOSAL_COUNT; i++)); do
  pid=$(yq ".proposals[$i].id" "$PROPOSAL_INDEX")
  if [[ "$pid" == "$PROPOSAL_ID" ]]; then
    PROPOSAL_FILE=$(yq ".proposals[$i].file" "$PROPOSAL_INDEX")
    break
  fi
done

SOURCE_PROPOSAL_PATH=""

if [[ -n "$PROPOSAL_FILE" ]]; then
  SOURCE_PROPOSAL_PATH="$PROPOSALS_DIR/$PROPOSAL_FILE"
  if [[ ! -f "$SOURCE_PROPOSAL_PATH" ]]; then
    # Mid-archival recovery: the proposal file may have already been moved to the archived
    # dir by a prior partial run (crash between file-move and index-rewrite). Fall through
    # to use the archived copy instead of erroring.
    if [[ -f "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE" ]]; then
      MID_ARCHIVAL=1
      SOURCE_PROPOSAL_PATH="$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE"
      evolve_log "INFO approve-global-proposal.sh: mid-archival recovery -- file already in archived dir"
    else
      evolve_log "approve-global-proposal.sh: live index references missing file $SOURCE_PROPOSAL_PATH"
      echo "ERROR: proposal file $SOURCE_PROPOSAL_PATH does not exist" >&2
      exit 1
    fi
  fi
else
  # Fall through to archived index (recovery from prior partial-failure run)
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
    evolve_log "INFO approve-global-proposal.sh: recovery mode -- proposal $PROPOSAL_ID found in archived index"
  else
    evolve_log "approve-global-proposal.sh: proposal $PROPOSAL_ID not found in live or archived index"
    echo "ERROR: proposal $PROPOSAL_ID not found in live or archived index" >&2
    exit 1
  fi
fi

# ── Read proposal type ────────────────────────────────────────────────────
PROP_TYPE=$(yq '.type // ""' "$SOURCE_PROPOSAL_PATH")
PROP_DOMAIN=$(yq '.domain // "unknown"' "$SOURCE_PROPOSAL_PATH" 2>/dev/null || echo "unknown")
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── Read auto_approve_target AFTER SOURCE_PROPOSAL_PATH is resolved ───────
AUTO_TARGET=$(yq '.auto_approve_target // false' "$SOURCE_PROPOSAL_PATH")

# ── Dispatch on proposal type ─────────────────────────────────────────────
case "$PROP_TYPE" in

  promotion)
    # ── Existing behavior: read trigger/action, build instinct YAML, call promote-instinct.sh ──
    PROPOSED_TRIGGER=$(yq '.proposed_trigger // ""' "$SOURCE_PROPOSAL_PATH")
    PROPOSED_ACTION=$(yq '.proposed_action // ""' "$SOURCE_PROPOSAL_PATH")

    # Read source_project_instincts
    SPI_COUNT=$(yq '.source_project_instincts | length' "$SOURCE_PROPOSAL_PATH" 2>/dev/null || echo "0")

    # Extract instinct ID from proposal ID (strip "global-proposal-" prefix and date suffix).
    # Confined here because this derivation is only correct for promotion proposals.
    INST_ID=$(echo "$PROPOSAL_ID" | sed 's/^global-proposal-//; s/-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}$//')

    # ── Build temp file for promote-instinct.sh ──────────────────────────
    TMP_INSTINCT=$(mktemp)

    SPI_YAML=""
    for ((i=0; i<SPI_COUNT; i++)); do
      proj=$(yq ".source_project_instincts[$i].project" "$SOURCE_PROPOSAL_PATH" 2>/dev/null || echo "")
      inst=$(yq ".source_project_instincts[$i].instinct" "$SOURCE_PROPOSAL_PATH" 2>/dev/null || echo "")
      SPI_YAML+="  - project: $proj"$'\n'
      SPI_YAML+="    instinct: $inst"$'\n'
    done

    PROPOSED_TRIGGER_ESC=$(yaml_escape_dq "$PROPOSED_TRIGGER")
    PROPOSED_ACTION_ESC=$(yaml_escape_dq "$PROPOSED_ACTION")

    cat > "$TMP_INSTINCT" <<ENDYAML
id: ${INST_ID}
trigger: "${PROPOSED_TRIGGER_ESC}"
action: "${PROPOSED_ACTION_ESC}"
domain: ${PROP_DOMAIN}
source_project_instincts:
${SPI_YAML}
ENDYAML

    # ── Call promote-instinct.sh under the global lock ──────────────────
    # We hold the global lock on fd 9; pass --no-lock so the child does not try
    # to re-acquire it. fd 9 is preserved across fork via OFD sharing, so the
    # global lock remains held throughout the child's execution. The child's
    # per-project locks (also fd 9) are scoped to the child and reassigning fd 9
    # in the child does not affect the parent's lock.
    #
    # Failures from the child (set -euo pipefail in the child, no evolve_trap
    # ERR handler) propagate as non-zero exit; the `if !` below catches them
    # and aborts before archiving the proposal.
    if ! "$EVOLVE_DIR/scripts/promote-instinct.sh" --no-lock "$TMP_INSTINCT"; then
      evolve_log "approve-global-proposal.sh: promote-instinct.sh failed for $PROPOSAL_ID"
      echo "ERROR: promote-instinct.sh failed for $PROPOSAL_ID" >&2
      rm -f "$TMP_INSTINCT"
      exit 1
    fi
    rm -f "$TMP_INSTINCT"

    # ── Verify the global instinct file was actually created ─────────────
    GLOBAL_INST_FILE="$GLOBAL_DIR/instincts/global-${INST_ID}.yaml"
    if [[ ! -f "$GLOBAL_INST_FILE" ]]; then
      evolve_log "approve-global-proposal.sh: global instinct file missing after promote: $GLOBAL_INST_FILE"
      echo "ERROR: global instinct file missing after promote: $GLOBAL_INST_FILE" >&2
      exit 1
    fi
    ;;

  memory)
    # ── Read memory proposal fields ───────────────────────────────────────
    NAME=$(yq '.name // ""' "$SOURCE_PROPOSAL_PATH")
    TITLE=$(yq '.title // ""' "$SOURCE_PROPOSAL_PATH")
    DESCRIPTION=$(yq '.description // ""' "$SOURCE_PROPOSAL_PATH")

    # source_global_instincts is a singleton list for single-instinct memory proposals.
    SGI_COUNT=$(yq '.source_global_instincts | length' "$SOURCE_PROPOSAL_PATH" 2>/dev/null || echo "0")

    # ── Compute destination path (mirrors what write-artifact.sh --scope global produces) ──
    DEST="$GLOBAL_DIR/memory/global-${NAME}.md"

    # ── Idempotent artifact write ─────────────────────────────────────────
    # Skip the write if the artifact already exists AND this is a recovery or auto-resume run.
    if [[ -f "$DEST" ]] && [[ $IS_RECOVERY -eq 1 || $MID_ARCHIVAL -eq 1 || "$AUTO_TARGET" == "true" ]]; then
      evolve_log "INFO approve-global-proposal.sh: artifact already at $DEST, skipping write (recovery or auto-resume)"
    else
      # Write proposed_content to a temp file and call write-artifact.sh.
      # Caller passes the BARE name; write-artifact.sh --scope global prepends global-.
      # Use // "" fallback so an absent proposed_content field yields empty string, not "null".
      CONTENT_FILE=$(mktemp)
      yq '.proposed_content // ""' "$SOURCE_PROPOSAL_PATH" > "$CONTENT_FILE"
      if ! "$EVOLVE_DIR/scripts/write-artifact.sh" --scope global "" memory "$NAME" "$CONTENT_FILE" "" >/dev/null; then
        evolve_log "approve-global-proposal.sh: write-artifact.sh failed for $PROPOSAL_ID"
        echo "ERROR: write-artifact.sh failed for $PROPOSAL_ID" >&2
        rm -f "$CONTENT_FILE"
        exit 1
      fi
      rm -f "$CONTENT_FILE"
    fi

    # ── Memory index append (idempotent) ──────────────────────────────────
    MEMORY_INDEX="$GLOBAL_DIR/memory/index.yaml"
    EXISTING_ENTRY=$(yq ".memories[] | select(.id == \"${PROPOSAL_ID}\") | .id" "$MEMORY_INDEX" 2>/dev/null || true)
    if [[ -z "$EXISTING_ENTRY" ]]; then
      TITLE_ESC=$(yaml_escape_dq "$TITLE")
      DESC_ESC=$(yaml_escape_dq "$DESCRIPTION")
      tmp_midx=$(mktemp)
      yq ".memories += [{
        \"id\": \"${PROPOSAL_ID}\",
        \"file\": \"global-${NAME}.md\",
        \"title\": \"${TITLE_ESC}\",
        \"description\": \"${DESC_ESC}\",
        \"source_proposal\": \"${PROPOSAL_ID}\",
        \"created\": \"${NOW}\"
      }]" "$MEMORY_INDEX" > "$tmp_midx"
      mv "$tmp_midx" "$MEMORY_INDEX"
    fi

    # ── Source global instinct archival (idempotent) ───────────────────────
    # Mirror approve-proposal.sh's source-instinct archival loop but against
    # $GLOBAL_DIR/instincts/.
    GLOBAL_INSTINCTS_DIR="$GLOBAL_DIR/instincts"
    GLOBAL_INSTINCT_INDEX="$GLOBAL_INSTINCTS_DIR/index.yaml"
    GLOBAL_INSTINCT_ARCHIVED_DIR="$GLOBAL_INSTINCTS_DIR/archived"
    GLOBAL_INSTINCT_ARCHIVED_INDEX="$GLOBAL_INSTINCT_ARCHIVED_DIR/index.yaml"

    # Read source_global_instincts into a bash array (bash 3.2 safe)
    SRC_IDS=()
    for ((i=0; i<SGI_COUNT; i++)); do
      SRC_IDS+=("$(yq ".source_global_instincts[$i]" "$SOURCE_PROPOSAL_PATH")")
    done

    # Guarded array expansion -- bash 3.2 + set -u trips on "${SRC_IDS[@]}" when array is empty.
    for INSTINCT_ID in ${SRC_IDS[@]+"${SRC_IDS[@]}"}; do
      INSTINCT_FILE="$GLOBAL_INSTINCTS_DIR/${INSTINCT_ID}.yaml"
      ARCHIVED_FILE="$GLOBAL_INSTINCT_ARCHIVED_DIR/${INSTINCT_ID}.yaml"

      if [[ ! -f "$INSTINCT_FILE" && -f "$ARCHIVED_FILE" ]]; then
        # Already archived -- check archived_by matches (idempotent re-run)
        ARCHIVED_BY=$(yq '.archived_by // ""' "$ARCHIVED_FILE")
        if [[ "$ARCHIVED_BY" == "$PROPOSAL_ID" ]]; then
          # Check GLOBAL_INSTINCT_ARCHIVED_INDEX has this id; repair if missing (partial-failure).
          ARCHIVED_INDEX_HAS=$(yq ".instincts[] | select(.id == \"${INSTINCT_ID}\") | .id" "$GLOBAL_INSTINCT_ARCHIVED_INDEX" 2>/dev/null || true)
          if [[ -z "$ARCHIVED_INDEX_HAS" ]]; then
            evolve_log "INFO approve-global-proposal.sh: archived index missing entry for $INSTINCT_ID; repairing"
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
            }]" "$GLOBAL_INSTINCT_ARCHIVED_INDEX" > "$tmp_arch"
            mv "$tmp_arch" "$GLOBAL_INSTINCT_ARCHIVED_INDEX"
          else
            evolve_log "INFO approve-global-proposal.sh: instinct $INSTINCT_ID already archived by this proposal"
          fi
          continue
        else
          evolve_log "WARN approve-global-proposal.sh: instinct $INSTINCT_ID archived by different proposal '$ARCHIVED_BY' -- skipping (manual intervention required)"
          continue
        fi
      fi

      if [[ ! -f "$INSTINCT_FILE" ]]; then
        evolve_log "WARN approve-global-proposal.sh: source instinct $INSTINCT_ID missing (not in live, not in archived)"
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
      yq ".instincts = [.instincts[] | select(.id != \"${INSTINCT_ID}\")]" "$GLOBAL_INSTINCT_INDEX" > "$tmp_idx"
      mv "$tmp_idx" "$GLOBAL_INSTINCT_INDEX"

      # Append to archived instincts index (atomic)
      tmp_arch=$(mktemp)
      yq ".instincts += [{
        \"id\": \"${INSTINCT_ID}\",
        \"domain\": \"${INSTINCT_DOMAIN}\",
        \"archived_reason\": \"proposal_approved\",
        \"archived_by\": \"${PROPOSAL_ID}\",
        \"archived_at\": \"${NOW}\",
        \"file\": \"${INSTINCT_ID}.yaml\"
      }]" "$GLOBAL_INSTINCT_ARCHIVED_INDEX" > "$tmp_arch"
      mv "$tmp_arch" "$GLOBAL_INSTINCT_ARCHIVED_INDEX"

      evolve_log "approve-global-proposal.sh: archived global instinct $INSTINCT_ID"
    done
    ;;

  *)
    evolve_log "approve-global-proposal.sh: unknown proposal type '$PROP_TYPE' for $PROPOSAL_ID"
    echo "ERROR: unknown proposal type '$PROP_TYPE' (expected promotion or memory)" >&2
    exit 1
    ;;
esac

# ── Common flow: archive proposal (gated on IS_RECOVERY -eq 0) ───────────
# IS_RECOVERY=1: full recovery (not in live, found in archived) -- skip everything.
# MID_ARCHIVAL=1: file already at archived path but still in live index -- skip
#   the file-move steps, but still run the live-index rewrite and archived-index append.
if [[ $IS_RECOVERY -eq 0 ]]; then
  if [[ $MID_ARCHIVAL -eq 0 ]]; then
    # Update proposal status and move to archived/
    tmp_prop=$(mktemp)
    yq "
      .status = \"approved\" |
      .resolved_at = \"${NOW}\"
    " "$SOURCE_PROPOSAL_PATH" > "$tmp_prop"

    # Move proposal to archived/
    mv "$tmp_prop" "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE"
    rm -f "$SOURCE_PROPOSAL_PATH"
  fi

  # Update proposals/index.yaml (atomic write) -- always runs when IS_RECOVERY=0.
  tmp_idx=$(mktemp)
  yq ".proposals = [.proposals[] | select(.id != \"${PROPOSAL_ID}\")]" "$PROPOSAL_INDEX" > "$tmp_idx"
  mv "$tmp_idx" "$PROPOSAL_INDEX"

  # ── Add to proposals/archived/index.yaml (atomic write, idempotent) ──────
  # Schema is type-discriminated:
  # - type=memory uses source_global_instincts / source_global_instinct_count
  # - type=promotion uses source_project_* (existing shape)
  # This divergence is intentional: promote.sh's Jaccard scan reads
  # source_project_instincts and silently no-ops on memory entries, so memory
  # entries in the archived index never produce false-positive promotion blocks.
  ALREADY_ARCH=$(yq "[.proposals[] | select(.id == \"${PROPOSAL_ID}\")] | length" "$PROPOSAL_ARCHIVED_INDEX" 2>/dev/null || echo "0")
  if [[ "$ALREADY_ARCH" -gt 0 ]]; then
    evolve_log "INFO approve-global-proposal.sh: archived index already has entry for $PROPOSAL_ID; skipping append"
  else
    tmp_arch=$(mktemp)
    case "$PROP_TYPE" in
      memory)
        # Build source_global_instincts JSON array for the archived index entry.
        SGI_ARCHIVED_YAML=""
        for ((i=0; i<SGI_COUNT; i++)); do
          sgi=$(yq ".source_global_instincts[$i]" "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE" 2>/dev/null || echo "")
          SGI_ARCHIVED_YAML+="\"${sgi}\", "
        done
        SGI_ARCHIVED_YAML="${SGI_ARCHIVED_YAML%, }"

        yq ".proposals += [{
          \"id\": \"${PROPOSAL_ID}\",
          \"type\": \"memory\",
          \"domain\": \"${PROP_DOMAIN}\",
          \"status\": \"approved\",
          \"resolved_at\": \"${NOW}\",
          \"source_global_instincts\": [${SGI_ARCHIVED_YAML}],
          \"source_global_instinct_count\": ${SGI_COUNT},
          \"file\": \"${PROPOSAL_FILE}\"
        }]" "$PROPOSAL_ARCHIVED_INDEX" > "$tmp_arch"
        ;;
      promotion)
        SRC_PROJECT_COUNT=$(yq '.source_project_count // 0' "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE" 2>/dev/null || echo "0")

        SPI_ARCHIVED_YAML=""
        for ((i=0; i<SPI_COUNT; i++)); do
          proj=$(yq ".source_project_instincts[$i].project" "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE" 2>/dev/null || echo "")
          inst=$(yq ".source_project_instincts[$i].instinct" "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE" 2>/dev/null || echo "")
          SPI_ARCHIVED_YAML+="{\"project\": \"${proj}\", \"instinct\": \"${inst}\"}, "
        done
        SPI_ARCHIVED_YAML="${SPI_ARCHIVED_YAML%, }"

        yq ".proposals += [{
          \"id\": \"${PROPOSAL_ID}\",
          \"type\": \"${PROP_TYPE}\",
          \"domain\": \"${PROP_DOMAIN}\",
          \"status\": \"approved\",
          \"resolved_at\": \"${NOW}\",
          \"source_project_count\": ${SRC_PROJECT_COUNT},
          \"source_project_instincts\": [${SPI_ARCHIVED_YAML}],
          \"file\": \"${PROPOSAL_FILE}\"
        }]" "$PROPOSAL_ARCHIVED_INDEX" > "$tmp_arch"
        ;;
      *)
        # Unknown type: write a minimal archived entry.
        yq ".proposals += [{
          \"id\": \"${PROPOSAL_ID}\",
          \"type\": \"${PROP_TYPE}\",
          \"domain\": \"${PROP_DOMAIN}\",
          \"status\": \"approved\",
          \"resolved_at\": \"${NOW}\",
          \"file\": \"${PROPOSAL_FILE}\"
        }]" "$PROPOSAL_ARCHIVED_INDEX" > "$tmp_arch"
        ;;
    esac
    mv "$tmp_arch" "$PROPOSAL_ARCHIVED_INDEX"
  fi
fi

# ── Release lock ──────────────────────────────────────────────────────────
release_lock "$GLOBAL_LOCK"
trap - EXIT

# ── Sync to git ───────────────────────────────────────────────────────────
evolve_git_push "evolve(approve-global): approved ${PROPOSAL_ID}"

evolve_log "approve-global-proposal.sh: approved proposal $PROPOSAL_ID (type=$PROP_TYPE)"
echo "approved: $PROPOSAL_ID"
exit 0
