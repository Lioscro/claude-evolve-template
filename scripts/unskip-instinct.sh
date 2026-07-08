#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$HOME/.claude/evolve/scripts/lib.sh"

# Log errors to evolve.log without swallowing exit code -- admin scripts must surface failures.
trap 'evolve_log "ERROR ${BASH_SOURCE[0]##*/}:$LINENO (exit $?)"' ERR

# ── Arguments ──────────────────────────────────────────────────────────────
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: unskip-instinct.sh PROJECT_ID INSTINCT_ID [--global]" >&2
  exit 1
fi
PROJECT_ID="$1"
INSTINCT_ID="$2"
GLOBAL_FLAG=""
if [[ $# -eq 3 ]]; then
  if [[ "$3" != "--global" ]]; then
    echo "ERROR: invalid 3rd arg '$3' (expected --global)" >&2
    exit 1
  fi
  GLOBAL_FLAG="--global"
fi

if ! validate_project_id "$PROJECT_ID"; then
  echo "ERROR: invalid PROJECT_ID (must match $_EVOLVE_PROJECT_ID_REGEX): $PROJECT_ID" >&2
  exit 1
fi
if ! validate_id "$INSTINCT_ID"; then
  echo "ERROR: invalid INSTINCT_ID (must match $_EVOLVE_ID_REGEX): $INSTINCT_ID" >&2
  exit 1
fi

# ── Resolve target paths ──────────────────────────────────────────────────
SIDECAR=""
LOCK_FILE=""
SCOPE_LABEL=""
if [[ "$GLOBAL_FLAG" == "--global" ]]; then
  if [[ ! -d "$GLOBAL_DIR" ]]; then
    echo "ERROR: global dir does not exist: $GLOBAL_DIR" >&2
    exit 1
  fi
  SIDECAR="$GLOBAL_DIR/instincts/.graduate-state.yaml"
  LOCK_FILE="$GLOBAL_DIR/global.lock"
  SCOPE_LABEL="global"
else
  PROJECT_DIR="$EVOLVE_DIR/projects/$PROJECT_ID"
  if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "ERROR: project dir does not exist: $PROJECT_DIR" >&2
    exit 1
  fi
  SIDECAR="$PROJECT_DIR/instincts/.graduate-state.yaml"
  LOCK_FILE="$PROJECT_DIR/evolve.lock"
  SCOPE_LABEL="project:$PROJECT_ID"
fi

# ── Acquire lock with explicit error handling ────────────────────────────
LOCK_ACQUIRED=0
if ! acquire_lock_blocking "$LOCK_FILE" 30; then
  echo "ERROR: could not acquire lock within 30s; another evolve process may be running" >&2
  exit 1
fi
LOCK_ACQUIRED=1
trap '[[ "$LOCK_ACQUIRED" -eq 1 ]] && release_lock "$LOCK_FILE"' EXIT

# ── Read sidecar; check for entry ────────────────────────────────────────
if [[ ! -f "$SIDECAR" ]]; then
  evolve_log "INFO unskip-instinct.sh: no skip entry for ${INSTINCT_ID} in ${SCOPE_LABEL} (sidecar absent)"
  release_lock "$LOCK_FILE"
  LOCK_ACQUIRED=0
  trap - EXIT
  exit 0
fi

EXISTING=$(yq ".skipped[] | select(.id == \"${INSTINCT_ID}\") | .id" "$SIDECAR" 2>/dev/null || true)
if [[ -z "$EXISTING" ]]; then
  evolve_log "INFO unskip-instinct.sh: no skip entry for ${INSTINCT_ID} in ${SCOPE_LABEL}"
  release_lock "$LOCK_FILE"
  LOCK_ACQUIRED=0
  trap - EXIT
  exit 0
fi

# ── Atomic-rewrite sidecar removing entry ────────────────────────────────
tmp_sc=$(mktemp)
yq ".skipped = [.skipped[] | select(.id != \"${INSTINCT_ID}\")]" "$SIDECAR" > "$tmp_sc"
mv "$tmp_sc" "$SIDECAR"

# ── Release lock and git push ────────────────────────────────────────────
release_lock "$LOCK_FILE"
LOCK_ACQUIRED=0
trap - EXIT

evolve_git_push "evolve(unskip): ${SCOPE_LABEL} ${INSTINCT_ID}"

evolve_log "unskip-instinct.sh: removed skip entry for ${INSTINCT_ID} in ${SCOPE_LABEL}"
echo "unskipped: $INSTINCT_ID ($SCOPE_LABEL)"
exit 0
