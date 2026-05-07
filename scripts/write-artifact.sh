#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$HOME/.claude/evolve/scripts/lib.sh"

# Log errors to evolve.log without swallowing exit code -- admin scripts must surface failures.
trap 'evolve_log "ERROR ${BASH_SOURCE[0]##*/}:$LINENO (exit $?)"' ERR

# ── Arguments ──────────────────────────────────────────────────────────────
PROJECT_ROOT="${1:?write-artifact.sh requires PROJECT_ROOT as \$1}"
TYPE="${2:?write-artifact.sh requires TYPE (skill/rule/memory) as \$2}"
NAME="${3:?write-artifact.sh requires NAME as \$3}"
CONTENT_FILE="${4:?write-artifact.sh requires CONTENT_FILE as \$4}"
PROJECT_ID="${5:?write-artifact.sh requires PROJECT_ID as \$5}"

if [[ ! -f "$CONTENT_FILE" ]]; then
  echo "ERROR: content file $CONTENT_FILE does not exist" >&2
  exit 1
fi

# ── Determine destination path ────────────────────────────────────────────
DEST=""

case "$TYPE" in
  skill)
    DEST="$PROJECT_ROOT/.claude/skills/evolve-${NAME}.md"
    ;;
  rule)
    DEST="$PROJECT_ROOT/.claude/rules/evolve-${NAME}.md"
    ;;
  memory)
    DEST="$EVOLVE_DIR/projects/${PROJECT_ID}/memory/${NAME}.md"
    ;;
  *)
    echo "ERROR: unknown artifact type '$TYPE' (expected skill, rule, or memory)" >&2
    exit 1
    ;;
esac

if [[ -e "$DEST" ]]; then
    echo "ERROR: $DEST already exists." >&2
    echo "       If this is a recovery from a prior partial-failure approval," >&2
    echo "       inspect the file and either delete it or retry approve-proposal.sh" >&2
    echo "       with the same proposal_id (idempotent re-run, will reuse the existing artifact)." >&2
    exit 1
fi

# ── Create parent directories ─────────────────────────────────────────────
mkdir -p "$(dirname "$DEST")"

# ── Write content ─────────────────────────────────────────────────────────
cp "$CONTENT_FILE" "$DEST"

evolve_log "write-artifact.sh: wrote $TYPE artifact to $DEST"
echo "$DEST"
exit 0
