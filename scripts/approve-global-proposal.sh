#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$HOME/.claude/evolve/scripts/lib.sh"

# Log errors to evolve.log without swallowing exit code -- admin scripts must surface failures.
trap 'evolve_log "ERROR ${BASH_SOURCE[0]##*/}:$LINENO (exit $?)"' ERR

# ── Arguments ──────────────────────────────────────────────────────────────
PROPOSAL_ID="${1:?approve-global-proposal.sh requires PROPOSAL_ID as \$1}"

# ── Check global dir exists ───────────────────────────────────────────────
if [[ ! -d "$GLOBAL_DIR" ]]; then
  evolve_log "approve-global-proposal.sh: global dir does not exist"
  echo "ERROR: global dir does not exist" >&2
  exit 1
fi

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

# ── Find proposal file via index ──────────────────────────────────────────
PROPOSAL_FILE=""
PROPOSAL_COUNT=$(yq '.proposals | length' "$PROPOSAL_INDEX" 2>/dev/null || echo "0")

for ((i=0; i<PROPOSAL_COUNT; i++)); do
  pid=$(yq ".proposals[$i].id" "$PROPOSAL_INDEX")
  if [[ "$pid" == "$PROPOSAL_ID" ]]; then
    PROPOSAL_FILE=$(yq ".proposals[$i].file" "$PROPOSAL_INDEX")
    break
  fi
done

if [[ -z "$PROPOSAL_FILE" ]]; then
  evolve_log "approve-global-proposal.sh: proposal $PROPOSAL_ID not found in index"
  echo "ERROR: proposal $PROPOSAL_ID not found in index" >&2
  exit 1
fi

PROPOSAL_PATH="$PROPOSALS_DIR/$PROPOSAL_FILE"
if [[ ! -f "$PROPOSAL_PATH" ]]; then
  evolve_log "approve-global-proposal.sh: proposal file $PROPOSAL_PATH does not exist"
  echo "ERROR: proposal file $PROPOSAL_PATH does not exist" >&2
  exit 1
fi

# ── Read proposal metadata ────────────────────────────────────────────────
PROPOSED_TRIGGER=$(yq '.proposed_trigger // ""' "$PROPOSAL_PATH")
PROPOSED_ACTION=$(yq '.proposed_action // ""' "$PROPOSAL_PATH")
PROP_DOMAIN=$(yq '.domain // "unknown"' "$PROPOSAL_PATH" 2>/dev/null || echo "unknown")

# Extract instinct ID from proposal ID (strip "global-proposal-" prefix and date suffix)
INST_ID=$(echo "$PROPOSAL_ID" | sed 's/^global-proposal-//; s/-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}$//')

# Read source_project_instincts
SPI_COUNT=$(yq '.source_project_instincts | length' "$PROPOSAL_PATH" 2>/dev/null || echo "0")

# ── Build temp file for promote-instinct.sh ───────────────────────────────
TMP_INSTINCT=$(mktemp)

SPI_YAML=""
for ((i=0; i<SPI_COUNT; i++)); do
  proj=$(yq ".source_project_instincts[$i].project" "$PROPOSAL_PATH" 2>/dev/null || echo "")
  inst=$(yq ".source_project_instincts[$i].instinct" "$PROPOSAL_PATH" 2>/dev/null || echo "")
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

# ── Call promote-instinct.sh under the global lock ───────────────────────
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

# ── Verify the global instinct file was actually created ────────────────
GLOBAL_INST_FILE="$GLOBAL_DIR/instincts/global-${INST_ID}.yaml"
if [[ ! -f "$GLOBAL_INST_FILE" ]]; then
  evolve_log "approve-global-proposal.sh: global instinct file missing after promote: $GLOBAL_INST_FILE"
  echo "ERROR: global instinct file missing after promote: $GLOBAL_INST_FILE" >&2
  exit 1
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── Update proposal status ────────────────────────────────────────────────
tmp_prop=$(mktemp)
yq "
  .status = \"approved\" |
  .resolved_at = \"${NOW}\"
" "$PROPOSAL_PATH" > "$tmp_prop"

# ── Move proposal to archived/ ───────────────────────────────────────────
mv "$tmp_prop" "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE"
rm -f "$PROPOSAL_PATH"

# ── Update proposals/index.yaml (atomic write) ───────────────────────────
tmp_idx=$(mktemp)
yq ".proposals = [.proposals[] | select(.id != \"${PROPOSAL_ID}\")]" "$PROPOSAL_INDEX" > "$tmp_idx"
mv "$tmp_idx" "$PROPOSAL_INDEX"

# ── Read source_project_instincts for archived index entry ────────────────
SPI_ARCHIVED_YAML=""
for ((i=0; i<SPI_COUNT; i++)); do
  proj=$(yq ".source_project_instincts[$i].project" "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE" 2>/dev/null || echo "")
  inst=$(yq ".source_project_instincts[$i].instinct" "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE" 2>/dev/null || echo "")
  SPI_ARCHIVED_YAML+="{\"project\": \"${proj}\", \"instinct\": \"${inst}\"}, "
done
SPI_ARCHIVED_YAML="${SPI_ARCHIVED_YAML%, }"

SRC_PROJECT_COUNT=$(yq '.source_project_count // 0' "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE" 2>/dev/null || echo "0")

# ── Add to proposals/archived/index.yaml (atomic write) ──────────────────
tmp_arch=$(mktemp)
yq ".proposals += [{
  \"id\": \"${PROPOSAL_ID}\",
  \"type\": \"promotion\",
  \"domain\": \"${PROP_DOMAIN}\",
  \"status\": \"approved\",
  \"resolved_at\": \"${NOW}\",
  \"source_project_count\": ${SRC_PROJECT_COUNT},
  \"source_project_instincts\": [${SPI_ARCHIVED_YAML}],
  \"file\": \"${PROPOSAL_FILE}\"
}]" "$PROPOSAL_ARCHIVED_INDEX" > "$tmp_arch"
mv "$tmp_arch" "$PROPOSAL_ARCHIVED_INDEX"

# ── Release lock ──────────────────────────────────────────────────────────
release_lock "$GLOBAL_LOCK"
trap - EXIT

# ── Sync to git ───────────────────────────────────────────────────────────
evolve_git_push "evolve(approve-global): approved ${PROPOSAL_ID}"

evolve_log "approve-global-proposal.sh: approved proposal $PROPOSAL_ID"
echo "approved: $PROPOSAL_ID"
exit 0
