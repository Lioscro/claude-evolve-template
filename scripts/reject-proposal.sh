#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$HOME/.claude/evolve/scripts/lib.sh"

# Log errors to evolve.log without swallowing exit code -- admin scripts must surface failures.
trap 'evolve_log "ERROR ${BASH_SOURCE[0]##*/}:$LINENO (exit $?)"' ERR

# ── Arguments ──────────────────────────────────────────────────────────────
PROJECT_ID="${1:?reject-proposal.sh requires PROJECT_ID as \$1}"
PROPOSAL_ID="${2:?reject-proposal.sh requires PROPOSAL_ID as \$2}"

# Parse --permanent flag
PERMANENT=0
if [[ "${3:-}" == "--permanent" ]]; then
  PERMANENT=1
fi

# ── Paths ──────────────────────────────────────────────────────────────────
PROJECT_DIR="$EVOLVE_DIR/projects/$PROJECT_ID"
PROPOSALS_DIR="$PROJECT_DIR/proposals"
PROPOSAL_INDEX="$PROPOSALS_DIR/index.yaml"
PROPOSAL_ARCHIVED_DIR="$PROPOSALS_DIR/archived"
PROPOSAL_ARCHIVED_INDEX="$PROPOSAL_ARCHIVED_DIR/index.yaml"
LOCK_FILE="$PROJECT_DIR/evolve.lock"

# ── Acquire lock (user-facing: error and exit 1 on contention) ────────────
if ! acquire_lock "$LOCK_FILE"; then
  evolve_log "reject-proposal.sh: lock held, cannot proceed"
  echo "ERROR: lock is held by another process. Try again shortly." >&2
  exit 1
fi
trap 'release_lock "$LOCK_FILE"' EXIT

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
  evolve_log "reject-proposal.sh: proposal $PROPOSAL_ID not found in index"
  echo "ERROR: proposal $PROPOSAL_ID not found in index" >&2
  exit 1
fi

PROPOSAL_PATH="$PROPOSALS_DIR/$PROPOSAL_FILE"
if [[ ! -f "$PROPOSAL_PATH" ]]; then
  evolve_log "reject-proposal.sh: proposal file $PROPOSAL_PATH does not exist"
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

# ── Read source_instincts for archived index entry ───────────────────────
SRC_COUNT=$(yq '.source_instincts | length' "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE" 2>/dev/null || echo "0")
SRC_INSTINCT_YAML=""
for ((i=0; i<SRC_COUNT; i++)); do
  sid=$(yq ".source_instincts[$i]" "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE")
  SRC_INSTINCT_YAML+="\"${sid}\", "
done
SRC_INSTINCT_YAML="${SRC_INSTINCT_YAML%, }"

PROP_TYPE=$(yq '.type // ""' "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE")
PROP_DOMAIN=$(yq '.domain // "unknown"' "$PROPOSAL_ARCHIVED_DIR/$PROPOSAL_FILE" 2>/dev/null || echo "unknown")

# ── Add to proposals/archived/index.yaml (atomic write) ──────────────────
tmp_arch=$(mktemp)
yq ".proposals += [{
  \"id\": \"${PROPOSAL_ID}\",
  \"type\": \"${PROP_TYPE}\",
  \"domain\": \"${PROP_DOMAIN}\",
  \"status\": \"${STATUS}\",
  \"resolved_at\": \"${NOW}\",
  \"source_instincts\": [${SRC_INSTINCT_YAML}],
  \"source_instinct_count\": ${SRC_COUNT},
  \"file\": \"${PROPOSAL_FILE}\"
}]" "$PROPOSAL_ARCHIVED_INDEX" > "$tmp_arch"
mv "$tmp_arch" "$PROPOSAL_ARCHIVED_INDEX"

# ── Release lock before git push (git-sync.lock is independent) ───────────
release_lock "$LOCK_FILE"
trap - EXIT

# ── Sync to git ───────────────────────────────────────────────────────────
evolve_git_push "evolve(reject): ${STATUS} ${PROPOSAL_ID}"

evolve_log "reject-proposal.sh: ${STATUS} proposal $PROPOSAL_ID"
echo "${STATUS}: $PROPOSAL_ID"
exit 0
