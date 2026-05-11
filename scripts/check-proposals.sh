#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$HOME/.claude/evolve/scripts/lib.sh"

# Trap errors -- log and exit 0 (never block Claude)
trap 'evolve_trap $LINENO $?' ERR

# ── Arguments ──────────────────────────────────────────────────────────────
PROJECT_ID="${1:?check-proposals.sh requires PROJECT_ID as \$1}"

# ── Paths ──────────────────────────────────────────────────────────────────
PROJECT_DIR="$EVOLVE_DIR/projects/$PROJECT_ID"
INDEX_FILE="$PROJECT_DIR/proposals/index.yaml"

if [[ ! -f "$INDEX_FILE" ]]; then
  exit 0
fi

# Count pending project proposals (all types)
PROJECT_COUNT=$(yq '.proposals | length' "$INDEX_FILE" 2>/dev/null || echo 0)

# Count pending project memory proposals specifically
PROJECT_MEMORY_COUNT=$(yq '[.proposals[] | select(.type == "memory")] | length' "$INDEX_FILE" 2>/dev/null || echo 0)

# Count pending global proposals broken out by type
GLOBAL_COUNT=0
GLOBAL_PROMOTION_COUNT=0
GLOBAL_MEMORY_COUNT=0
GLOBAL_INDEX="$GLOBAL_DIR/proposals/index.yaml"
if [[ -d "$GLOBAL_DIR" && -f "$GLOBAL_INDEX" ]]; then
  GLOBAL_COUNT=$(yq '.proposals | length' "$GLOBAL_INDEX" 2>/dev/null || echo 0)
  GLOBAL_PROMOTION_COUNT=$(yq '[.proposals[] | select(.type == "promotion")] | length' "$GLOBAL_INDEX" 2>/dev/null || echo 0)
  GLOBAL_MEMORY_COUNT=$(yq '[.proposals[] | select(.type == "memory")] | length' "$GLOBAL_INDEX" 2>/dev/null || echo 0)
fi

# ── Build notification message ──────────────────────────────────────────────
if [[ "$PROJECT_COUNT" -gt 0 && "$GLOBAL_COUNT" -gt 0 ]]; then
  # Combined: project + global
  # Build parts list, skip zero counts
  msg="[claude-evolve]"
  parts=""

  if [[ "$PROJECT_COUNT" -gt 0 ]]; then
    project_part="$PROJECT_COUNT project proposal(s)"
    if [[ "$PROJECT_MEMORY_COUNT" -gt 0 ]]; then
      project_part="$PROJECT_COUNT project proposal(s) (incl. $PROJECT_MEMORY_COUNT memory)"
    fi
    parts="$project_part"
  fi

  if [[ "$GLOBAL_PROMOTION_COUNT" -gt 0 ]]; then
    if [[ -n "$parts" ]]; then
      parts="$parts, $GLOBAL_PROMOTION_COUNT global promotion(s)"
    else
      parts="$GLOBAL_PROMOTION_COUNT global promotion(s)"
    fi
  fi

  if [[ "$GLOBAL_MEMORY_COUNT" -gt 0 ]]; then
    if [[ -n "$parts" ]]; then
      parts="$parts, $GLOBAL_MEMORY_COUNT global memory proposal(s)"
    else
      parts="$GLOBAL_MEMORY_COUNT global memory proposal(s)"
    fi
  fi

  # Fallback for unknown-typed global proposals (parity with the global-only branch).
  if [[ "$GLOBAL_PROMOTION_COUNT" -eq 0 && "$GLOBAL_MEMORY_COUNT" -eq 0 ]]; then
    if [[ -n "$parts" ]]; then
      parts="$parts, $GLOBAL_COUNT global proposal(s)"
    else
      parts="$GLOBAL_COUNT global proposal(s)"
    fi
  fi

  echo "$msg $parts pending. Run /evolve to review."

elif [[ "$PROJECT_COUNT" -gt 0 ]]; then
  # Project only
  project_part="$PROJECT_COUNT pending proposal(s)"
  if [[ "$PROJECT_MEMORY_COUNT" -gt 0 ]]; then
    project_part="$PROJECT_COUNT pending proposal(s) (incl. $PROJECT_MEMORY_COUNT memory)"
  fi
  echo "[claude-evolve] $project_part. Run /evolve to review."

elif [[ "$GLOBAL_COUNT" -gt 0 ]]; then
  # Global only: show separate counts, skip zeros
  global_parts=""
  if [[ "$GLOBAL_PROMOTION_COUNT" -gt 0 ]]; then
    global_parts="$GLOBAL_PROMOTION_COUNT global promotion(s)"
  fi
  if [[ "$GLOBAL_MEMORY_COUNT" -gt 0 ]]; then
    if [[ -n "$global_parts" ]]; then
      global_parts="$global_parts, $GLOBAL_MEMORY_COUNT global memory proposal(s)"
    else
      global_parts="$GLOBAL_MEMORY_COUNT global memory proposal(s)"
    fi
  fi
  # Fallback: if no typed counts resolved (unexpected), use total
  if [[ -z "$global_parts" ]]; then
    global_parts="$GLOBAL_COUNT global proposal(s)"
  fi
  echo "[claude-evolve] $global_parts pending. Run /evolve to review."
fi

# ── Unreachable-threshold warnings ─────────────────────────────────────────
if [[ -f "$PROJECT_DIR/.graduation-warning" ]]; then
  echo "[claude-evolve] Graduation thresholds invalid in project; see evolve.log."
fi
if [[ -d "$GLOBAL_DIR" && -f "$GLOBAL_DIR/.graduation-warning" ]]; then
  echo "[claude-evolve] Graduation thresholds invalid in global; see evolve.log."
fi

exit 0
