#!/usr/bin/env bash
set -euo pipefail

# apply-compression.sh <project_id> | --global  <cid>
#
# Applies one staged compression (produced by compress.sh): an in-place, 1->1
# rewrite of an instinct's trigger/action (file + denormalized index trigger) or
# a memory's body (.md) + index title/description. Re-validates under the lock:
#   - if the entry already equals the compressed form -> idempotent success;
#   - if the live entry changed since analysis -> ABORT (exit 3, staging kept),
#     so the /compress skill re-runs analysis (never clobbers a concurrent edit).
# Nothing is merged, archived, renamed, or re-id'd. Confidence, provenance, and
# entry count are untouched. On success: removes staging, git-pushes.
#
# Sourcing with EVOLVE_APPLY_COMPRESS_LIB=1 defines the functions without running.

source "$HOME/.claude/evolve/scripts/lib.sh"
trap 'evolve_log "ERROR ${BASH_SOURCE[0]##*/}:$LINENO (exit $?)"' ERR

# sha_of <file> -- content checksum (see compress.sh). Byte-exact change-detection.
sha_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else cksum "$1" 2>/dev/null | awk '{print $1"-"$2}'; fi
}

# abort_cid <message> -- leave staging in place, tell the user to re-run analyze.
abort_cid() {
  release_lock "$LOCK_FILE" 2>/dev/null || true
  trap - EXIT
  evolve_log "apply-compression.sh: abort $CID -- $1"
  echo "ABORTED: $1" >&2
  echo "The entry changed since analysis. Re-run /compress to refresh." >&2
  exit 3
}

# ── Instinct apply (rewrite trigger/action in place) ─────────────────────────
apply_instinct() {
  local idir="$BASE_DIR/instincts"
  local index="$idir/index.yaml"
  local sid orig_trigger orig_action new_trigger new_action
  sid=$(yq '.source_id' "$SF")
  orig_trigger=$(yq '.orig_trigger // ""' "$SF"); orig_action=$(yq '.orig_action // ""' "$SF")
  new_trigger=$(yq '.compressed_trigger // ""' "$SF"); new_action=$(yq '.compressed_action // ""' "$SF")
  validate_id "$sid" || abort_cid "invalid source_id '$sid'"
  [[ -n "$new_trigger" && -n "$new_action" ]] || abort_cid "empty compressed trigger/action"

  local ifile="$idir/${sid}.yaml"
  [[ -f "$ifile" ]] || abort_cid "source instinct '$sid' no longer present"
  local present
  present=$(yq "[.instincts[] | select(.id == \"$sid\")] | length" "$index" 2>/dev/null || echo 0)
  [[ "$present" -ge 1 ]] || abort_cid "source instinct '$sid' missing from live index"

  local live_trigger live_action
  live_trigger=$(yq '.trigger // ""' "$ifile" 2>/dev/null || echo "")
  live_action=$(yq '.action // ""' "$ifile" 2>/dev/null || echo "")

  # Idempotent: already compressed.
  if [[ "$live_trigger" == "$new_trigger" && "$live_action" == "$new_action" ]]; then
    evolve_log "apply-compression.sh: $CID already applied ('$sid')"
    RESULT="compressed instinct ${sid} (already applied)"
    return 0
  fi
  # Change-detection: live must match what we compressed from.
  if [[ "$live_trigger" != "$orig_trigger" || "$live_action" != "$orig_action" ]]; then
    abort_cid "instinct '$sid' changed since analysis"
  fi

  # Rewrite the instinct file (trigger + action) via strenv (injection-safe).
  local tmp; tmp=$(mktemp)
  T="$new_trigger" A="$new_action" yq '.trigger = strenv(T) | .action = strenv(A)' "$ifile" > "$tmp"
  [[ -s "$tmp" ]] || { rm -f "$tmp"; abort_cid "yq produced empty instinct file for '$sid'"; }
  mv "$tmp" "$ifile"

  # Rewrite the denormalized trigger in the index (action is not stored there).
  local tmp_idx; tmp_idx=$(mktemp)
  ID="$sid" T="$new_trigger" yq "(.instincts[] | select(.id == strenv(ID))).trigger = strenv(T)" "$index" > "$tmp_idx"
  [[ -s "$tmp_idx" ]] || { rm -f "$tmp_idx"; abort_cid "yq produced empty index"; }
  mv "$tmp_idx" "$index"

  evolve_log "apply-compression.sh: compressed instinct '$sid'"
  RESULT="compressed instinct ${sid}"
}

# ── Memory apply (rewrite body in place + index title/description) ───────────
apply_memory() {
  local mdir="$BASE_DIR/memory"
  local index="$mdir/index.yaml"
  local sid new_title new_description orig_sha
  sid=$(yq '.source_id' "$SF")
  new_title=$(yq '.compressed_title // ""' "$SF"); new_description=$(yq '.compressed_description // ""' "$SF")
  orig_sha=$(yq '.orig_content_sha // ""' "$SF")
  [[ -n "$sid" ]] || abort_cid "empty source_id"

  local present mfile
  present=$(yq "[.memories[] | select(.id == \"$sid\")] | length" "$index" 2>/dev/null || echo 0)
  [[ "$present" -ge 1 ]] || abort_cid "source memory '$sid' no longer present"
  mfile=$(yq ".memories[] | select(.id == \"$sid\") | .file" "$index" 2>/dev/null || echo "")
  [[ -n "$mfile" && -f "$mdir/$mfile" ]] || abort_cid "source memory body missing for '$sid'"

  local new_cfile; new_cfile=$(mktemp)
  yq '.compressed_content // ""' "$SF" > "$new_cfile"
  [[ -s "$new_cfile" ]] || { rm -f "$new_cfile"; abort_cid "empty compressed_content"; }

  local live_sha new_sha
  live_sha=$(sha_of "$mdir/$mfile")
  new_sha=$(sha_of "$new_cfile")

  # Idempotent: body already equals the compressed form.
  if [[ -n "$live_sha" && "$live_sha" == "$new_sha" ]]; then
    rm -f "$new_cfile"
    evolve_log "apply-compression.sh: $CID already applied ('$sid')"
    RESULT="compressed memory ${sid} (already applied)"
    return 0
  fi
  # Change-detection: live body must match what we compressed from (skip only if
  # the staging file carried no checksum, e.g. a degraded environment).
  if [[ -n "$orig_sha" && -n "$live_sha" && "$live_sha" != "$orig_sha" ]]; then
    rm -f "$new_cfile"
    abort_cid "memory '$sid' body changed since analysis"
  fi

  # Overwrite the body in place (write-artifact.sh is no-clobber, so write directly).
  mv "$new_cfile" "$mdir/$mfile"

  # Update the denormalized title/description in the index.
  local tmp_idx; tmp_idx=$(mktemp)
  ID="$sid" TT="$new_title" DD="$new_description" yq "
    (.memories[] | select(.id == strenv(ID))).title = strenv(TT) |
    (.memories[] | select(.id == strenv(ID))).description = strenv(DD)
  " "$index" > "$tmp_idx"
  [[ -s "$tmp_idx" ]] || { rm -f "$tmp_idx"; abort_cid "yq produced empty index"; }
  mv "$tmp_idx" "$index"

  evolve_log "apply-compression.sh: compressed memory '$sid'"
  RESULT="compressed memory ${sid}"
}

# When sourced for testing, stop here.
if [[ "${EVOLVE_APPLY_COMPRESS_LIB:-}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

# ── Arguments / scope ────────────────────────────────────────────────────────
if [[ "${1:-}" == "--global" ]]; then
  SCOPE="global"; PROJECT_ID=""; CID="${2:?usage: apply-compression.sh --global <cid>}"
elif [[ -n "${1:-}" && -n "${2:-}" ]]; then
  SCOPE="project"; PROJECT_ID="$1"; CID="$2"
else
  echo "usage: apply-compression.sh <project_id>|--global <cid>" >&2
  exit 1
fi
validate_id "$CID" || { echo "apply-compression.sh: invalid cid '$CID'" >&2; exit 1; }
[[ "$CID" == compression-* ]] || { echo "apply-compression.sh: not a compression id '$CID'" >&2; exit 1; }

if [[ "$SCOPE" == "global" ]]; then
  init_global
  BASE_DIR="$GLOBAL_DIR"; LOCK_FILE="$GLOBAL_DIR/global.lock"
  STAGING_DIR="$EVOLVE_DIR/compressions/global"
else
  validate_project_id "$PROJECT_ID" || { echo "apply-compression.sh: invalid project id" >&2; exit 1; }
  init_project "$PROJECT_ID"
  BASE_DIR="$EVOLVE_DIR/projects/$PROJECT_ID"; LOCK_FILE="$BASE_DIR/evolve.lock"
  STAGING_DIR="$EVOLVE_DIR/compressions/$PROJECT_ID"
fi

SF="$STAGING_DIR/${CID}.yaml"
if [[ ! -f "$SF" ]]; then
  echo "apply-compression.sh: staging file not found: $SF" >&2
  exit 1
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── Acquire lock (block; approval must wait, not skip) ───────────────────────
if ! acquire_lock_blocking "$LOCK_FILE" 30; then
  echo "apply-compression.sh: lock busy, try again shortly" >&2
  exit 1
fi
trap 'release_lock "$LOCK_FILE" 2>/dev/null' EXIT

# ── Load staging + dispatch ──────────────────────────────────────────────────
ENTRY_TYPE=$(yq '.entry_type' "$SF" 2>/dev/null || echo "")
STAGE_SCOPE=$(yq '.scope' "$SF" 2>/dev/null || echo "")
if [[ "$STAGE_SCOPE" != "$SCOPE" ]]; then
  release_lock "$LOCK_FILE"; trap - EXIT
  echo "apply-compression.sh: scope mismatch (staging=$STAGE_SCOPE, arg=$SCOPE)" >&2
  exit 1
fi

RESULT=""
case "$ENTRY_TYPE" in
  instinct) apply_instinct ;;
  memory)   apply_memory ;;
  *)
    release_lock "$LOCK_FILE"; trap - EXIT
    echo "apply-compression.sh: unknown entry_type '$ENTRY_TYPE'" >&2
    exit 1 ;;
esac

# ── Success: remove staging, release, push ───────────────────────────────────
rm -f "$SF"
release_lock "$LOCK_FILE"
trap - EXIT
evolve_git_push "evolve(compress): applied ${CID}"
evolve_log "apply-compression.sh: applied ${CID} (${RESULT})"
echo "$RESULT"
exit 0
