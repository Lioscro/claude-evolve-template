#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$HOME/.claude/evolve/scripts/lib.sh"

# Log errors to evolve.log without swallowing exit code -- admin scripts must surface failures.
trap 'evolve_log "ERROR ${BASH_SOURCE[0]##*/}:$LINENO (exit $?)"' ERR

# ── Arguments ──────────────────────────────────────────────────────────────
# Usage: write-artifact.sh [--scope project|global] PROJECT_ROOT TYPE NAME CONTENT_FILE PROJECT_ID
#
# --scope is optional; defaults to "project". Must be the first argument if present.
# PROJECT_ROOT may be "" when TYPE=memory (memory destinations live under $EVOLVE_DIR, not PROJECT_ROOT).
# For TYPE=skill or TYPE=rule, PROJECT_ROOT must be non-empty.
#
# Note: approve-proposal.sh's existing call (line ~141) does not pass --scope and uses
# the legacy 5-positional form; this continues to work because --scope parsing is opt-in.

# Parse optional --scope flag first (must be $1 if present).
if [[ "${1:-}" == "--scope" ]]; then
  SCOPE="$2"
  shift 2
else
  SCOPE="project"
fi

# Validate SCOPE.
if [[ "$SCOPE" != "project" && "$SCOPE" != "global" ]]; then
  echo "ERROR: invalid --scope '$SCOPE' (expected project or global)" >&2
  exit 1
fi

# Read positional args (PROJECT_ROOT is now optional for memory types).
PROJECT_ROOT="${1:-}"
TYPE="${2:?write-artifact.sh requires TYPE (skill/rule/memory) as \$2}"
NAME="${3:?write-artifact.sh requires NAME as \$3}"
CONTENT_FILE="${4:?write-artifact.sh requires CONTENT_FILE as \$4}"
PROJECT_ID="${5:-}"

# Global scope is only supported for memory (global skills/rules not yet supported).
if [[ "$SCOPE" == "global" && "$TYPE" != "memory" ]]; then
  echo "ERROR: --scope global is only supported for type=memory (global skills/rules not yet supported; TODO)" >&2
  exit 1
fi

# PROJECT_ID is required for project-scope memory (and skill/rule -- checked below in case block).
if [[ "$SCOPE" == "project" && "$TYPE" == "memory" && -z "$PROJECT_ID" ]]; then
  echo "ERROR: PROJECT_ID is required for project-scope memory" >&2
  exit 1
fi

if [[ ! -f "$CONTENT_FILE" ]]; then
  echo "ERROR: content file $CONTENT_FILE does not exist" >&2
  exit 1
fi

# ── Determine destination path ────────────────────────────────────────────
DEST=""

case "$TYPE" in
  skill)
    # PROJECT_ROOT is required for skill artifacts.
    if [[ -z "$PROJECT_ROOT" ]]; then
      echo "ERROR: PROJECT_ROOT is required for type=skill" >&2
      exit 1
    fi
    DEST="$PROJECT_ROOT/.claude/skills/evolve-${NAME}.md"
    ;;
  rule)
    # PROJECT_ROOT is required for rule artifacts.
    if [[ -z "$PROJECT_ROOT" ]]; then
      echo "ERROR: PROJECT_ROOT is required for type=rule" >&2
      exit 1
    fi
    DEST="$PROJECT_ROOT/.claude/rules/evolve-${NAME}.md"
    ;;
  memory)
    # PROJECT_ROOT is unused for memory (destination lives under $EVOLVE_DIR or $GLOBAL_DIR).
    if [[ "$SCOPE" == "global" ]]; then
      # Always prepend global- to NAME; callers pass the bare name.
      # The memory-writer agent's prompt forbids names starting with global- to prevent double-prefix.
      DEST="$GLOBAL_DIR/memory/global-${NAME}.md"
    else
      DEST="$EVOLVE_DIR/projects/${PROJECT_ID}/memory/${NAME}.md"
    fi
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
