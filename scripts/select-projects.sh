#!/usr/bin/env bash
# select-projects.sh -- resolve an optional user-typed arg to one or more project_ids.
#
# NOT the same as resolve-project.sh -- that one maps cwd -> project_id; this one
# maps a user-typed arg to one or more project_ids.
#
# Usage: select-projects.sh [ARG]
#
#   No arg (or whitespace-only): print the project_id derived from $(pwd), provided
#     that project already has evolve data on disk. Otherwise exit 3.
#   ARG == "all" (reserved keyword, case-sensitive): print every project directory
#     under $EVOLVE_DIR/projects/ (excluding hidden entries and non-directories),
#     sorted LC_ALL=C. Exit 0, possibly with empty stdout.
#   ARG == anything else: exact match against a project directory name wins;
#     otherwise case-sensitive substring match against all project directory names.
#     Exactly one match -> print it, exit 0. Zero matches -> exit 1. Multiple matches
#     -> exit 2. Errors go to stderr.
#
# Exit codes:
#   0 -- success
#   1 -- no match for a specific arg
#   2 -- ambiguous match for a specific arg
#   3 -- internal error (projects dir missing; or empty-arg cwd-derived id not present)
#
# This is a user-facing CLI; it does NOT register evolve_trap (errors must surface).
# Runs on macOS default bash 3.2 -- no associative arrays, no mapfile/readarray,
# no ${!arr[@]} indirection, no `grep | ...` under pipefail.

set -euo pipefail

EVOLVE_DIR="$HOME/.claude/evolve"
# shellcheck source=/dev/null
source "$EVOLVE_DIR/scripts/lib.sh"

arg="$(printf '%s' "${1:-}" | tr -d '[:space:]')"

# -----------------------------------------------------------------------------
# Empty arg: resolve from cwd.
# -----------------------------------------------------------------------------
if [[ -z "$arg" ]]; then
  cwd_id="$(resolve_project "$(pwd)")"
  if [[ -d "$EVOLVE_DIR/projects/$cwd_id" ]]; then
    printf '%s\n' "$cwd_id"
    exit 0
  fi
  printf 'ERROR: no evolve data for this project yet (cwd: %s, derived id: %s). Run a session to initialize.\n' \
    "$(pwd)" "$cwd_id" >&2
  exit 3
fi

# -----------------------------------------------------------------------------
# Projects-dir guard (shared by `all` and specific-arg branches).
# -----------------------------------------------------------------------------
if [[ ! -d "$EVOLVE_DIR/projects" ]]; then
  printf 'ERROR: %s/projects does not exist. Install claude-evolve or run a session first.\n' \
    "$EVOLVE_DIR" >&2
  exit 3
fi

# -----------------------------------------------------------------------------
# Enumerate all project directory names (sorted, hidden excluded).
# -----------------------------------------------------------------------------
all_ids=""
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  all_ids="${all_ids}${name}"$'\n'
done < <(LC_ALL=C find "$EVOLVE_DIR/projects/" -mindepth 1 -maxdepth 1 -type d -not -name '.*' -exec basename {} \; | LC_ALL=C sort)

# -----------------------------------------------------------------------------
# Reserved keyword `all` (case-sensitive): print every enumerated id.
# -----------------------------------------------------------------------------
if [[ "$arg" == "all" ]]; then
  # all_ids already has a trailing newline (or is empty). printf %s preserves it.
  printf '%s' "$all_ids"
  exit 0
fi

# -----------------------------------------------------------------------------
# Specific arg: exact match wins.
# -----------------------------------------------------------------------------
if [[ -d "$EVOLVE_DIR/projects/$arg" ]]; then
  printf '%s\n' "$arg"
  exit 0
fi

# -----------------------------------------------------------------------------
# Substring match. Build candidate list without `grep | ...` (pipefail-safe).
# -----------------------------------------------------------------------------
candidates=""
candidate_count=0
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  if [[ $name == *"$arg"* ]]; then
    candidates="${candidates}${name}"$'\n'
    candidate_count=$((candidate_count + 1))
  fi
done <<< "$all_ids"

# Sort candidates (already sorted since all_ids is sorted, but be explicit).
if [[ -n "$candidates" ]]; then
  candidates="$(printf '%s' "$candidates" | LC_ALL=C sort)"
  candidates="${candidates}"$'\n'
fi

if [[ "$candidate_count" -eq 1 ]]; then
  printf '%s' "$candidates"
  exit 0
fi

if [[ "$candidate_count" -eq 0 ]]; then
  # Zero substring matches: list available ids (cap at 15).
  printf "ERROR: no project matches '%s'. Available:\n" "$arg" >&2
  total=0
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    total=$((total + 1))
  done <<< "$all_ids"

  shown=0
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if [[ "$shown" -lt 15 ]]; then
      printf '  %s\n' "$name" >&2
      shown=$((shown + 1))
    fi
  done <<< "$all_ids"

  if [[ "$total" -gt 15 ]]; then
    remaining=$((total - 15))
    printf '  ... and %d more\n' "$remaining" >&2
  fi
  exit 1
fi

# More than one substring match: ambiguous.
printf "ERROR: ambiguous match for '%s'. Candidates:\n" "$arg" >&2
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  printf '  %s\n' "$name" >&2
done <<< "$candidates"
exit 2
