#!/usr/bin/env bash
set -euo pipefail

# check-config-defaults.sh
#
# Verifies that every validate_numeric callsite in scripts/*.sh uses a fallback
# value matching the `// X` literal in the corresponding read_config call's yq
# path expression. This guards against fallback drift over time (e.g. config.yaml
# default updated but a caller's hardcoded fallback not).
#
# Strategy: for each validate_numeric line, walk backward up to 5 lines looking
# for a read_config assignment to the same variable. Compare the // X literal
# in the yq path against the validate_numeric's third argument.
#
# Exit non-zero if any mismatches found.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS=("$SCRIPT_DIR"/*.sh)

MISMATCHES=0
CHECKED=0
MISSING=0

for f in "${SCRIPTS[@]}"; do
  # Skip self
  [[ "$f" == */check-config-defaults.sh ]] && continue
  [[ -f "$f" ]] || continue

  # Read all lines into an array
  lines=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    lines+=("$line")
  done < "$f"

  num_lines=${#lines[@]}
  i=0
  while [[ $i -lt $num_lines ]]; do
    line="${lines[$i]}"

    # Match: VAR=$(validate_numeric "$VAR" "$_NUMERIC_..." "FALLBACK")
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=\$\(validate_numeric[[:space:]]+\"\$([A-Za-z_][A-Za-z0-9_]*)\"[[:space:]]+\"\$(_NUMERIC_NONNEG_FLOAT|_NUMERIC_NONNEG_INT)\"[[:space:]]+\"([^\"]+)\"\) ]]; then
      varname="${BASH_REMATCH[1]}"
      ref_var="${BASH_REMATCH[2]}"
      regex_const="${BASH_REMATCH[3]}"
      fallback="${BASH_REMATCH[4]}"
      lineno=$((i + 1))

      if [[ "$varname" != "$ref_var" ]]; then
        echo "WARN $f:$lineno: validate_numeric var ($ref_var) does not match assigned var ($varname)" >&2
      fi

      # Walk backward up to 5 lines for the read_config assignment
      yq_default=""
      found=0
      j=$((i - 1))
      lookback_limit=$((i - 5))
      [[ $lookback_limit -lt 0 ]] && lookback_limit=0
      while [[ $j -ge $lookback_limit ]]; do
        candidate="${lines[$j]}"
        # Match: VAR=$(read_config '.path // X' [args])
        # The // X literal can be a number with optional decimal (e.g. 0.5, 100, 0.03)
        if [[ "$candidate" =~ ^[[:space:]]*${varname}=\$\(read_config[[:space:]]+\'[^\']*//[[:space:]]*([^[:space:]\']+)[[:space:]]*\' ]]; then
          yq_default="${BASH_REMATCH[1]}"
          found=1
          break
        fi
        j=$((j - 1))
      done

      CHECKED=$((CHECKED + 1))

      if [[ $found -eq 0 ]]; then
        echo "MISSING $f:$lineno: no matching read_config for variable $varname within 5 prior lines" >&2
        MISSING=$((MISSING + 1))
      else
        if [[ "$yq_default" != "$fallback" ]]; then
          echo "MISMATCH $f:$lineno: validate_numeric fallback '$fallback' != read_config default '$yq_default' (var: $varname)" >&2
          MISMATCHES=$((MISMATCHES + 1))
        fi
      fi
    fi

    i=$((i + 1))
  done
done

echo "check-config-defaults.sh: checked $CHECKED validate_numeric callsite(s)"
if [[ $MISMATCHES -gt 0 ]]; then
  echo "FAIL: $MISMATCHES fallback/default mismatch(es)" >&2
fi
if [[ $MISSING -gt 0 ]]; then
  echo "FAIL: $MISSING missing read_config callsite(s)" >&2
fi

if [[ $MISMATCHES -gt 0 || $MISSING -gt 0 ]]; then
  exit 1
fi

echo "OK: all fallbacks match read_config defaults"
exit 0
