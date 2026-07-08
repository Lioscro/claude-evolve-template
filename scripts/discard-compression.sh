#!/usr/bin/env bash
set -euo pipefail

# discard-compression.sh <project_id> | --global  <cid>
#
# Drops a staged compression (rejected in review). Removes only the transient
# staging file; touches no durable state and does not git-push.

source "$HOME/.claude/evolve/scripts/lib.sh"
trap 'evolve_log "ERROR ${BASH_SOURCE[0]##*/}:$LINENO (exit $?)"' ERR

if [[ "${1:-}" == "--global" ]]; then
  SCOPE="global"; PROJECT_ID=""; CID="${2:?usage: discard-compression.sh --global <cid>}"
elif [[ -n "${1:-}" && -n "${2:-}" ]]; then
  SCOPE="project"; PROJECT_ID="$1"; CID="$2"
else
  echo "usage: discard-compression.sh <project_id>|--global <cid>" >&2
  exit 1
fi

validate_id "$CID" || { echo "discard-compression.sh: invalid cid '$CID'" >&2; exit 1; }
[[ "$CID" == compression-* ]] || { echo "discard-compression.sh: not a compression id '$CID'" >&2; exit 1; }

if [[ "$SCOPE" == "global" ]]; then
  STAGING_DIR="$EVOLVE_DIR/compressions/global"
else
  validate_project_id "$PROJECT_ID" || { echo "discard-compression.sh: invalid project id" >&2; exit 1; }
  STAGING_DIR="$EVOLVE_DIR/compressions/$PROJECT_ID"
fi

SF="$STAGING_DIR/${CID}.yaml"
if [[ -f "$SF" ]]; then
  rm -f "$SF"
  evolve_log "discard-compression.sh: discarded $CID"
  echo "discarded $CID"
else
  echo "already gone: $CID"
fi
exit 0
