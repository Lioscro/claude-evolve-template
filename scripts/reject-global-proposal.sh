#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$HOME/.claude/evolve/scripts/lib.sh"

# Log errors to evolve.log without swallowing exit code -- admin scripts must surface failures.
trap 'evolve_log "ERROR ${BASH_SOURCE[0]##*/}:$LINENO (exit $?)"' ERR

# ── Arguments ──────────────────────────────────────────────────────────────
PROPOSAL_ID="${1:?reject-global-proposal.sh requires PROPOSAL_ID as \$1}"

# Parse --permanent flag
PERMANENT=0
if [[ "${2:-}" == "--permanent" ]]; then
  PERMANENT=1
fi

# ── Check global dir exists ───────────────────────────────────────────────
if [[ ! -d "$GLOBAL_DIR" ]]; then
  evolve_log "reject-global-proposal.sh: global dir does not exist"
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
  evolve_log "reject-global-proposal.sh: global lock held, cannot proceed"
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
  evolve_log "reject-global-proposal.sh: proposal $PROPOSAL_ID not found in index"
  echo "ERROR: proposal $PROPOSAL_ID not found in index" >&2
  exit 1
fi

PROPOSAL_PATH="$PROPOSALS_DIR/$PROPOSAL_FILE"
if [[ ! -f "$PROPOSAL_PATH" ]]; then
  evolve_log "reject-global-proposal.sh: proposal file $PROPOSAL_PATH does not exist"
  echo "ERROR: proposal file $PROPOSAL_PATH does not exist" >&2
  exit 1
fi

# ── Determine status ─────────────────────────────────────────────────────
if [[ "$PERMANENT" -eq 1 ]]; then
  STATUS="permanently_rejected"
else
  STATUS="rejected"
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── Update proposal status ────────────────────────────────────────────────
tmp_prop=$(mktemp)
yq "
  .status = \"${STATUS}\" |
  .resolved_at = \"${NOW}\"
" "$PROPOSAL_PATH" > "$tmp_prop"

# ── Move proposal to archived/ ───────────────────────────────────────────
mv "$tmp_prop" "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE"
rm -f "$PROPOSAL_PATH"

# ── Update proposals/index.yaml (atomic write) ───────────────────────────
tmp_idx=$(mktemp)
yq ".proposals = [.proposals[] | select(.id != \"${PROPOSAL_ID}\")]" "$PROPOSAL_INDEX" > "$tmp_idx"
mv "$tmp_idx" "$PROPOSAL_INDEX"

# ── Read metadata from archived proposal for index entry ─────────────────
PROP_DOMAIN=$(yq '.domain // "unknown"' "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE" 2>/dev/null || echo "unknown")
SRC_PROJECT_COUNT=$(yq '.source_project_count // 0' "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE" 2>/dev/null || echo "0")

# Read source_project_instincts for archived index entry (needed for Jaccard overlap check)
SPI_COUNT=$(yq '.source_project_instincts | length' "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE" 2>/dev/null || echo "0")
SPI_ARCHIVED_YAML=""
for ((i=0; i<SPI_COUNT; i++)); do
  proj=$(yq ".source_project_instincts[$i].project" "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE" 2>/dev/null || echo "")
  inst=$(yq ".source_project_instincts[$i].instinct" "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE" 2>/dev/null || echo "")
  SPI_ARCHIVED_YAML+="{\"project\": \"${proj}\", \"instinct\": \"${inst}\"}, "
done
SPI_ARCHIVED_YAML="${SPI_ARCHIVED_YAML%, }"

# ── Add to proposals/archived/index.yaml (atomic write) ──────────────────
tmp_arch=$(mktemp)
yq ".proposals += [{
  \"id\": \"${PROPOSAL_ID}\",
  \"type\": \"promotion\",
  \"domain\": \"${PROP_DOMAIN}\",
  \"status\": \"${STATUS}\",
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
evolve_git_push "evolve(reject-global): ${STATUS} ${PROPOSAL_ID}"

evolve_log "reject-global-proposal.sh: ${STATUS} proposal $PROPOSAL_ID"
echo "${STATUS}: $PROPOSAL_ID"
exit 0
