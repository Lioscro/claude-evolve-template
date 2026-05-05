#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$HOME/.claude/evolve/scripts/lib.sh"

# Trap errors -- log and exit 0 (never block Claude)
trap 'evolve_trap $LINENO $?' ERR

# ── Arguments ──────────────────────────────────────────────────────────────
# Optional leading flag: --no-global or --global-only (mutually exclusive).
# Argument-validation errors use explicit `exit 1`; `exit` does not trigger
# ERR, so these cleanly bypass `evolve_trap` (which exits 0).
SHOW_PROJECT=1
SHOW_GLOBAL=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-global)
      if [[ "$SHOW_PROJECT" == "0" ]]; then
        echo "ERROR: --no-global and --global-only are mutually exclusive" >&2
        exit 1
      fi
      SHOW_GLOBAL=0
      shift
      ;;
    --global-only)
      if [[ "$SHOW_GLOBAL" == "0" ]]; then
        echo "ERROR: --no-global and --global-only are mutually exclusive" >&2
        exit 1
      fi
      SHOW_PROJECT=0
      shift
      ;;
    --*)
      echo "ERROR: unknown flag $1" >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

# ── Paths ──────────────────────────────────────────────────────────────────
# --global-only skips all project-side work (no resolve_project call, no
# project index reads). Any trailing positional arg is accepted but ignored.
if [[ "$SHOW_PROJECT" == "1" ]]; then
  PROJECT_ID="${1:-$(resolve_project "$(pwd)")}"
  PROJECT_DIR="$EVOLVE_DIR/projects/$PROJECT_ID"
  if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "ERROR: no evolve data for project '$PROJECT_ID' at $PROJECT_DIR" >&2
    exit 1
  fi
fi

# ── Count helper ───────────────────────────────────────────────────────────
# count_jsonl <dir> -- count .jsonl files in a directory (bash 3.2 safe)
count_jsonl() {
  local dir="$1"
  local n=0
  for f in "$dir"/*.jsonl; do
    [[ -f "$f" ]] || continue
    n=$((n + 1))
  done
  echo "$n"
}

# ── Detail printers ────────────────────────────────────────────────────────
# Items are grouped by domain (alphabetical). Within a domain, instincts are
# sorted by confidence descending; proposals by id alphabetical. Each domain
# group is preceded by an indented header with a `─` underline.

# domain_underline <text>: emit `─` repeated for the visible width of <text>.
# Domain names are ASCII so ${#text} == display width.
domain_underline() {
  local text="$1"
  local out=""
  local j=0
  while [[ $j -lt ${#text} ]]; do
    out="${out}─"
    j=$((j + 1))
  done
  printf '%s\n' "$out"
}

# print_instincts <label> <index_file> <items_dir>
# Emits "[claude-evolve] <label>" header, then a domain-grouped listing of
# active instincts. Each item shows `id (conf X.YZ)` with indented `when:` and
# `do:` lines. No-ops when the index is empty/missing.
print_instincts() {
  local label="$1" index_file="$2" items_dir="$3"
  [[ -s "$index_file" ]] || return 0
  local n
  n=$(yq '.instincts | length' "$index_file" 2>/dev/null || echo 0)
  [[ "$n" -gt 0 ]] || return 0

  echo ""
  echo "[claude-evolve] $label"

  # Build sortable rows: domain<TAB>conf<TAB>idx
  local TAB=$'\t'
  local rows=""
  local i=0
  while [[ $i -lt $n ]]; do
    local d c
    d=$(yq ".instincts[$i].domain // \"unknown\"" "$index_file" 2>/dev/null)
    c=$(yq ".instincts[$i].confidence // 0" "$index_file" 2>/dev/null)
    rows+="${d}${TAB}${c}${TAB}${i}"$'\n'
    i=$((i + 1))
  done

  # Sort: domain alpha, then confidence general-numeric reversed
  local sorted
  sorted=$(printf '%s' "$rows" | sort -t"$TAB" -k1,1 -k2,2gr)

  local last_domain=""
  while IFS=$'\t' read -r domain conf idx; do
    [[ -z "$idx" ]] && continue
    if [[ "$domain" != "$last_domain" ]]; then
      echo ""
      printf '  %s\n' "$domain"
      printf '  %s\n' "$(domain_underline "$domain")"
      last_domain="$domain"
    fi

    local id trigger file action
    id=$(yq ".instincts[$idx].id // \"\"" "$index_file" 2>/dev/null)
    trigger=$(yq ".instincts[$idx].trigger // \"\"" "$index_file" 2>/dev/null)
    file=$(yq ".instincts[$idx].file // \"\"" "$index_file" 2>/dev/null)
    action=""
    if [[ -n "$file" && -f "$items_dir/$file" ]]; then
      action=$(yq '.action // ""' "$items_dir/$file" 2>/dev/null)
    fi
    printf '  • %s  (conf %s)\n' "$id" "$conf"
    [[ -n "$trigger" && "$trigger" != "null" ]] && printf '      when: %s\n' "$trigger"
    [[ -n "$action" && "$action" != "null" ]] && printf '      do:   %s\n' "$action"
  done <<< "$sorted"
}

# print_proposals <label> <index_file> <items_dir>
# Emits "[claude-evolve] <label>" header, then a domain-grouped listing of
# active proposals. Each item shows `id (type, status)` with indented title
# and description lines pulled from the per-proposal file. No-ops when empty.
print_proposals() {
  local label="$1" index_file="$2" items_dir="$3"
  [[ -s "$index_file" ]] || return 0
  local n
  n=$(yq '.proposals | length' "$index_file" 2>/dev/null || echo 0)
  [[ "$n" -gt 0 ]] || return 0

  echo ""
  echo "[claude-evolve] $label"

  local TAB=$'\t'
  local rows=""
  local i=0
  while [[ $i -lt $n ]]; do
    local d id_
    d=$(yq ".proposals[$i].domain // \"unknown\"" "$index_file" 2>/dev/null)
    id_=$(yq ".proposals[$i].id // \"\"" "$index_file" 2>/dev/null)
    rows+="${d}${TAB}${id_}${TAB}${i}"$'\n'
    i=$((i + 1))
  done

  local sorted
  sorted=$(printf '%s' "$rows" | sort -t"$TAB" -k1,1 -k2,2)

  local last_domain=""
  while IFS=$'\t' read -r domain id_ idx; do
    [[ -z "$idx" ]] && continue
    if [[ "$domain" != "$last_domain" ]]; then
      echo ""
      printf '  %s\n' "$domain"
      printf '  %s\n' "$(domain_underline "$domain")"
      last_domain="$domain"
    fi

    local ptype status file title description
    ptype=$(yq ".proposals[$idx].type // \"\"" "$index_file" 2>/dev/null)
    status=$(yq ".proposals[$idx].status // \"\"" "$index_file" 2>/dev/null)
    file=$(yq ".proposals[$idx].file // \"\"" "$index_file" 2>/dev/null)
    title=""
    description=""
    if [[ -n "$file" && -f "$items_dir/$file" ]]; then
      title=$(yq '.title // ""' "$items_dir/$file" 2>/dev/null)
      description=$(yq '.description // ""' "$items_dir/$file" 2>/dev/null)
    fi
    printf '  • %s  (%s, %s)\n' "$id_" "$ptype" "$status"
    [[ -n "$title" && "$title" != "null" ]] && printf '      title: %s\n' "$title"
    [[ -n "$description" && "$description" != "null" ]] && printf '      desc:  %s\n' "$description"
  done <<< "$sorted"
}

# ── Counts ─────────────────────────────────────────────────────────────────
TOTAL=0
if [[ "$SHOW_PROJECT" == "1" ]]; then
  OBS_ACTIVE=$(count_jsonl "$PROJECT_DIR/observations")
  OBS_ARCHIVED=$(count_jsonl "$PROJECT_DIR/observations/archived")

  INST_ACTIVE=$(yq '.instincts | length' "$PROJECT_DIR/instincts/index.yaml" 2>/dev/null || echo 0)
  INST_ARCHIVED=$(yq '.instincts | length' "$PROJECT_DIR/instincts/archived/index.yaml" 2>/dev/null || echo 0)

  PROP_ACTIVE=$(yq '.proposals | length' "$PROJECT_DIR/proposals/index.yaml" 2>/dev/null || echo 0)
  PROP_ARCHIVED=$(yq '.proposals | length' "$PROJECT_DIR/proposals/archived/index.yaml" 2>/dev/null || echo 0)

  TOTAL=$((OBS_ACTIVE + OBS_ARCHIVED + INST_ACTIVE + INST_ARCHIVED + PROP_ACTIVE + PROP_ARCHIVED))
fi

# ── Global counts (gracefully handle missing $GLOBAL_DIR) ──────────────────
GLOBAL_INST_ACTIVE=0
GLOBAL_INST_ARCHIVED=0
GLOBAL_PROP_ACTIVE=0
GLOBAL_PROP_ARCHIVED=0

if [[ "$SHOW_GLOBAL" == "1" && -d "$GLOBAL_DIR" ]]; then
  GLOBAL_INST_ACTIVE=$(yq '.instincts | length' "$GLOBAL_DIR/instincts/index.yaml" 2>/dev/null || echo 0)
  GLOBAL_INST_ARCHIVED=$(yq '.instincts | length' "$GLOBAL_DIR/instincts/archived/index.yaml" 2>/dev/null || echo 0)
  GLOBAL_PROP_ACTIVE=$(yq '.proposals | length' "$GLOBAL_DIR/proposals/index.yaml" 2>/dev/null || echo 0)
  GLOBAL_PROP_ARCHIVED=$(yq '.proposals | length' "$GLOBAL_DIR/proposals/archived/index.yaml" 2>/dev/null || echo 0)
fi

GLOBAL_TOTAL=$((GLOBAL_INST_ACTIVE + GLOBAL_INST_ARCHIVED + GLOBAL_PROP_ACTIVE + GLOBAL_PROP_ARCHIVED))

# ── Output ─────────────────────────────────────────────────────────────────
# "no data yet" fires only when BOTH sections would be printed and both
# totals are zero. With --no-global or --global-only, suppress it.
if [[ "$SHOW_PROJECT" == "1" && "$SHOW_GLOBAL" == "1" ]]; then
  if [[ "$TOTAL" -gt 0 || "$GLOBAL_TOTAL" -gt 0 ]]; then
    echo "[claude-evolve] observations: $OBS_ACTIVE ($OBS_ARCHIVED archived) | instincts: $INST_ACTIVE ($INST_ARCHIVED archived) | proposals: $PROP_ACTIVE ($PROP_ARCHIVED archived)"
    print_instincts "instincts (project)" "$PROJECT_DIR/instincts/index.yaml" "$PROJECT_DIR/instincts"
    print_proposals "proposals (project)" "$PROJECT_DIR/proposals/index.yaml" "$PROJECT_DIR/proposals"
    if [[ "$GLOBAL_TOTAL" -gt 0 ]]; then
      echo ""
      echo "[claude-evolve] global: instincts: $GLOBAL_INST_ACTIVE ($GLOBAL_INST_ARCHIVED archived) | proposals: $GLOBAL_PROP_ACTIVE ($GLOBAL_PROP_ARCHIVED archived)"
      print_instincts "instincts (global)" "$GLOBAL_DIR/instincts/index.yaml" "$GLOBAL_DIR/instincts"
      print_proposals "proposals (global)" "$GLOBAL_DIR/proposals/index.yaml" "$GLOBAL_DIR/proposals"
    fi
  else
    echo "[claude-evolve] no data yet"
  fi
elif [[ "$SHOW_PROJECT" == "1" ]]; then
  # --no-global: emit project line only when there's project data; empty otherwise.
  if [[ "$TOTAL" -gt 0 ]]; then
    echo "[claude-evolve] observations: $OBS_ACTIVE ($OBS_ARCHIVED archived) | instincts: $INST_ACTIVE ($INST_ARCHIVED archived) | proposals: $PROP_ACTIVE ($PROP_ARCHIVED archived)"
    print_instincts "instincts (project)" "$PROJECT_DIR/instincts/index.yaml" "$PROJECT_DIR/instincts"
    print_proposals "proposals (project)" "$PROJECT_DIR/proposals/index.yaml" "$PROJECT_DIR/proposals"
  fi
else
  # --global-only: emit global line only when global data exists; empty otherwise.
  if [[ "$GLOBAL_TOTAL" -gt 0 ]]; then
    echo "[claude-evolve] global: instincts: $GLOBAL_INST_ACTIVE ($GLOBAL_INST_ARCHIVED archived) | proposals: $GLOBAL_PROP_ACTIVE ($GLOBAL_PROP_ARCHIVED archived)"
    print_instincts "instincts (global)" "$GLOBAL_DIR/instincts/index.yaml" "$GLOBAL_DIR/instincts"
    print_proposals "proposals (global)" "$GLOBAL_DIR/proposals/index.yaml" "$GLOBAL_DIR/proposals"
  fi
fi

exit 0
