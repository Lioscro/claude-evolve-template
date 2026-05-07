#!/usr/bin/env bash
set -euo pipefail

# Read ALL of stdin before anything else (hook input JSON).
INPUT=$(cat)

# Source shared library
source "$HOME/.claude/evolve/scripts/lib.sh"

# Trap errors -- log and exit 0 (never block Claude)
trap 'evolve_trap $LINENO $?' ERR

# Exit early if running inside an evolve agent subprocess
if evolve_is_subprocess; then
  exit 0
fi

# Exit early if evolve is disabled
if ! evolve_enabled; then
  exit 0
fi

# Extract cwd from hook input
CWD=$(echo "$INPUT" | jq -r '.cwd')

# Resolve project
PROJECT_ID=$(resolve_project "$CWD")

# Path to instinct index
INDEX_FILE="$EVOLVE_DIR/projects/$PROJECT_ID/instincts/index.yaml"
INSTINCTS_DIR="$EVOLVE_DIR/projects/$PROJECT_ID/instincts"

# Read project injection threshold (global threshold is read inside the global section)
INJECTION_THRESHOLD=$(read_config '.instincts.injection_threshold // 0.5' "$PROJECT_ID" 2>/dev/null || echo "0.5")
INJECTION_THRESHOLD=$(validate_numeric "$INJECTION_THRESHOLD" "$_NUMERIC_NONNEG_FLOAT" "0.5")
TAB=$'\t'

# ── Project instinct injection ───────────────────────────────────────────────

PROJECT_OUTPUT=""
if [[ -s "$INDEX_FILE" ]]; then
  MAX_INJECTED=$(read_config '.instincts.max_injected // 10' "$PROJECT_ID" 2>/dev/null || echo "10")
  MAX_INJECTED=$(validate_numeric "$MAX_INJECTED" "$_NUMERIC_NONNEG_INT" "10")

  INSTINCT_COUNT=$(yq '.instincts | length' "$INDEX_FILE" 2>/dev/null || echo "0")
  if [[ "$INSTINCT_COUNT" -gt 0 ]]; then
    # Extract all instinct data from index in a single yq call.
    # Output format: one line per instinct, tab-separated: confidence\ttrigger\tfile
    ALL_INSTINCTS=$(yq ".instincts[] | (.confidence | tostring) + \"${TAB}\" + .trigger + \"${TAB}\" + .file" "$INDEX_FILE" 2>/dev/null || true)

    if [[ -n "$ALL_INSTINCTS" ]]; then
      CANDIDATES=""
      while IFS=$'\t' read -r CONF _TRIGGER _FILE; do
        [[ -z "$CONF" ]] && continue
        if (( $(echo "$CONF >= $INJECTION_THRESHOLD" | bc -l) )); then
          CANDIDATES+="${CONF}${TAB}${_TRIGGER}${TAB}${_FILE}"$'\n'
        fi
      done <<< "$ALL_INSTINCTS"

      if [[ -n "$CANDIDATES" ]]; then
        SORTED=$(echo -n "$CANDIDATES" | sort -t$'\t' -k1 -rn | head -n "$MAX_INJECTED")

        while IFS=$'\t' read -r CONF TRIGGER INST_FILE; do
          [[ -z "$CONF" ]] && continue
          ACTION=""
          if [[ -f "$INSTINCTS_DIR/$INST_FILE" ]]; then
            ACTION=$(yq '.action // ""' "$INSTINCTS_DIR/$INST_FILE" 2>/dev/null || true)
          fi
          if [[ -n "$ACTION" ]]; then
            PROJECT_OUTPUT+="- When ${TRIGGER}: ${ACTION} (confidence: ${CONF})"$'\n'
          else
            PROJECT_OUTPUT+="- When ${TRIGGER} (confidence: ${CONF})"$'\n'
          fi
        done <<< "$SORTED"
      fi
    fi
  fi
fi

# ── Global instinct injection ────────────────────────────────────────────────
# Inject global instincts under a separate header. Gracefully skip if
# $GLOBAL_DIR or its index doesn't exist (install.sh not re-run).

GLOBAL_OUTPUT=""
GLOBAL_INDEX="$GLOBAL_DIR/instincts/index.yaml"
if [[ -s "$GLOBAL_INDEX" ]]; then
  GLOBAL_MAX_INJECTED=$(read_config '.global_instincts.max_injected // 5' "$PROJECT_ID" 2>/dev/null || echo "5")
  GLOBAL_MAX_INJECTED=$(validate_numeric "$GLOBAL_MAX_INJECTED" "$_NUMERIC_NONNEG_INT" "5")
  GLOBAL_INJECTION_THRESHOLD=$(read_config '.global_instincts.injection_threshold // 0.5' "$PROJECT_ID" 2>/dev/null || echo "0.5")
  GLOBAL_INJECTION_THRESHOLD=$(validate_numeric "$GLOBAL_INJECTION_THRESHOLD" "$_NUMERIC_NONNEG_FLOAT" "0.5")

  GLOBAL_COUNT=$(yq '.instincts | length' "$GLOBAL_INDEX" 2>/dev/null || echo "0")
  if [[ "$GLOBAL_COUNT" -gt 0 ]]; then
    ALL_GLOBAL=$(yq ".instincts[] | (.confidence | tostring) + \"${TAB}\" + .trigger + \"${TAB}\" + .file" "$GLOBAL_INDEX" 2>/dev/null || true)

    if [[ -n "$ALL_GLOBAL" ]]; then
      GLOBAL_CANDIDATES=""
      while IFS=$'\t' read -r CONF _TRIGGER _FILE; do
        [[ -z "$CONF" ]] && continue
        if (( $(echo "$CONF >= $GLOBAL_INJECTION_THRESHOLD" | bc -l) )); then
          GLOBAL_CANDIDATES+="${CONF}${TAB}${_TRIGGER}${TAB}${_FILE}"$'\n'
        fi
      done <<< "$ALL_GLOBAL"

      if [[ -n "$GLOBAL_CANDIDATES" ]]; then
        GLOBAL_SORTED=$(echo -n "$GLOBAL_CANDIDATES" | sort -t$'\t' -k1 -rn | head -n "$GLOBAL_MAX_INJECTED")

        while IFS=$'\t' read -r CONF TRIGGER INST_FILE; do
          [[ -z "$CONF" ]] && continue
          ACTION=""
          if [[ -f "$GLOBAL_DIR/instincts/$INST_FILE" ]]; then
            ACTION=$(yq '.action // ""' "$GLOBAL_DIR/instincts/$INST_FILE" 2>/dev/null || true)
          fi
          if [[ -n "$ACTION" ]]; then
            GLOBAL_OUTPUT+="- When ${TRIGGER}: ${ACTION} (confidence: ${CONF})"$'\n'
          else
            GLOBAL_OUTPUT+="- When ${TRIGGER} (confidence: ${CONF})"$'\n'
          fi
        done <<< "$GLOBAL_SORTED"
      fi
    fi
  fi
fi

# ── Output ───────────────────────────────────────────────────────────────────
# Exit silently if nothing to output from either section.
if [[ -z "$PROJECT_OUTPUT" ]] && [[ -z "$GLOBAL_OUTPUT" ]]; then
  exit 0
fi

if [[ -n "$PROJECT_OUTPUT" ]]; then
  echo "[claude-evolve] Active instincts for this project:"
  echo -n "$PROJECT_OUTPUT"
fi

if [[ -n "$GLOBAL_OUTPUT" ]]; then
  echo "[claude-evolve] Active global instincts:"
  echo -n "$GLOBAL_OUTPUT"
fi

exit 0
