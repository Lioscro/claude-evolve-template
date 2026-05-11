#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$HOME/.claude/evolve/scripts/lib.sh"

# Log errors to evolve.log without swallowing exit code -- admin scripts must surface failures.
trap 'evolve_log "ERROR ${BASH_SOURCE[0]##*/}:$LINENO (exit $?)"' ERR

# ── Arguments ──────────────────────────────────────────────────────────────
PROPOSAL_ID="${1:?reject-global-proposal.sh requires PROPOSAL_ID as \$1}"

if ! validate_id "$PROPOSAL_ID"; then
  echo "ERROR: invalid PROPOSAL_ID (must match $_EVOLVE_ID_REGEX): $PROPOSAL_ID" >&2
  exit 1
fi

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

# ── Determine status ─────────────────────────────────────────────────────
if [[ "$PERMANENT" -eq 1 ]]; then
  STATUS="permanently_rejected"
else
  STATUS="rejected"
fi

# ── Archive proposal via shared helper ───────────────────────────────────
# Deliberate semantics shift: the prior code exited 1 when the live proposal
# file was missing (lines 65-69 in the original). The helper's recovery branch
# instead self-heals by re-syncing the indexes against the already-archived file.
# This is the correct behavior for an interrupted prior run.
arch_rc=0
archive_proposal "$PROPOSAL_PATH" "$PROPOSAL_ID" \
  "$PROPOSAL_ARCHIVED_DIR" "$PROPOSAL_ARCHIVED_INDEX" \
  "$PROPOSAL_INDEX" "$STATUS" --scope global || arch_rc=$?
if [[ "$arch_rc" -ne 0 ]]; then
  evolve_log "reject-global-proposal.sh: archive_proposal failed (rc=$arch_rc) for $PROPOSAL_ID"
  echo "ERROR: archive_proposal failed for $PROPOSAL_ID" >&2
  exit 1
fi

# ── Release lock ──────────────────────────────────────────────────────────
release_lock "$GLOBAL_LOCK"
trap - EXIT

# ── Sync to git ───────────────────────────────────────────────────────────
evolve_git_push "evolve(reject-global): ${STATUS} ${PROPOSAL_ID}"

evolve_log "reject-global-proposal.sh: ${STATUS} proposal $PROPOSAL_ID"
echo "${STATUS}: $PROPOSAL_ID"
exit 0
