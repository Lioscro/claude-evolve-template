#!/usr/bin/env bash
set -euo pipefail

# compress.sh <project_id> | --global
#
# ANALYSIS ONLY. Rewrites verbose instinct trigger/action text and memory bodies
# to be terse WITHOUT changing meaning, identity, confidence, or count (a 1->1
# rewrite). Asks a compressor agent per entry type and writes one *staging* file
# per proposed rewrite under
#   $EVOLVE_DIR/compressions/<project_id>/   (project scope)
#   $EVOLVE_DIR/compressions/global/         (global scope)
# It NEVER mutates instincts/memories and NEVER git-pushes. The /compress skill
# presents the staged rewrites; apply-compression.sh applies an approved one;
# discard-compression.sh drops a rejected one.
#
# Staging lives OUTSIDE data/ so evolve_git_push (git add data/...) never commits
# this transient per-machine working state.
#
# Sourcing with EVOLVE_COMPRESS_LIB=1 defines the functions but does not run the
# passes (used by the hermetic parser test).

source "$HOME/.claude/evolve/scripts/lib.sh"

# User-invoked (via skill): surface failures, do not silently exit 0.
trap 'evolve_log "ERROR ${BASH_SOURCE[0]##*/}:$LINENO (exit $?)"' ERR

emit() { evolve_log "compress.sh: $*"; echo "$*"; }

# ── Generic helpers ──────────────────────────────────────────────────────────

# clear_staging <entry_type> -- remove this scope's prior pending staging for a
# pass so a fresh analysis run supersedes it (staged rewrites are recomputable).
clear_staging() {
  local et="$1" f
  for f in "$STAGING_DIR"/compression-"$et"-*.yaml; do
    if [[ -e "$f" ]]; then rm -f "$f"; fi
  done
  return 0
}

# invoke_compressor <agent_basename> <input> -- runs the agent with the configured
# model, prints raw output. Returns 1 on invocation failure or a NONE/empty result.
invoke_compressor() {
  local agent_base="$1" input="$2" out trimmed
  out=$(printf '%s\n' "$input" | EVOLVE_AGENT_MODEL_OVERRIDE="$AGENT_MODEL" invoke_agent "$EVOLVE_DIR/agents/${agent_base}.md" 2>/dev/null) || {
    evolve_log "compress.sh: agent $agent_base invocation failed"
    return 1
  }
  trimmed=$(printf '%s' "$out" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [[ -z "$trimmed" || "$trimmed" == "NONE" ]]; then
    return 1
  fi
  printf '%s' "$out"
}

# split_docs <agent_output> <callback_fn> -- splits on bare `---` lines (indented
# `---` inside block scalars is preserved) and calls <callback_fn> per document.
split_docs() {
  local out="$1" cb="$2" cur="" line
  while IFS= read -r line; do
    if [[ "$line" == "---" ]]; then
      if [[ -n "$cur" ]]; then "$cb" "$cur"; fi
      cur=""
    else
      cur+="$line"$'\n'
    fi
  done <<< "$out"
  if [[ -n "$cur" ]]; then "$cb" "$cur"; fi
  return 0
}

# yq_field <path> <tmp_doc> -- read a scalar field, empty on error.
yq_field() { yq "$1 // \"\"" "$2" 2>/dev/null || echo ""; }

# sha_of <file> -- content checksum for change-detection (byte-exact, avoids
# YAML block-scalar round-trip issues). Prefers shasum (macOS), then sha256sum,
# then cksum (POSIX fallback -- non-cryptographic but fine for change-detection).
sha_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else cksum "$1" 2>/dev/null | awk '{print $1"-"$2}'; fi
}

# ── Per-pass state (reset at the start of each pass) ─────────────────────────
_SEEN=""        # newline-separated source ids already staged in this pass
_PASS_STAGED=0

reset_pass() { _SEEN=""; _PASS_STAGED=0; }

# any_seen <id> -- returns 0 if the id is already staged this pass.
any_seen() {
  local id="$1"
  [[ -z "$id" ]] && return 1
  printf '%s\n' "$_SEEN" | grep -qx "$id"
}

mark_seen() { _SEEN+="$1"$'\n'; }

# ── Instinct pass ────────────────────────────────────────────────────────────
process_instinct_doc() {
  local doc="$1" tmp
  doc=$(printf '%s' "$doc" | sed '/^```yaml$/d; /^```$/d')
  tmp=$(mktemp)
  printf '%s' "$doc" > "$tmp"

  local sid trigger action
  sid=$(yq_field '.source_id' "$tmp")
  trigger=$(yq_field '.compressed_trigger' "$tmp")
  action=$(yq_field '.compressed_action' "$tmp")
  rm -f "$tmp"

  [[ "$_PASS_STAGED" -ge "$MAX_PER_RUN" ]] && return
  if [[ -z "$sid" || -z "$trigger" || -z "$action" ]]; then
    evolve_log "compress.sh(instinct): skip doc (sid=$sid)"; return
  fi
  if ! validate_id "$sid"; then evolve_log "compress.sh(instinct): skip bad source_id '$sid'"; return; fi
  local ifile="$BASE_DIR/instincts/${sid}.yaml"
  if [[ ! -f "$ifile" ]]; then evolve_log "compress.sh(instinct): skip -- '$sid' not in snapshot"; return; fi
  if any_seen "$sid"; then evolve_log "compress.sh(instinct): skip -- '$sid' already staged"; return; fi

  local cid="compression-instinct-${sid}-${EPOCH_NOW}"
  if [[ "${#cid}" -gt 128 ]]; then evolve_log "compress.sh(instinct): skip -- cid too long for '$sid'"; return; fi

  local orig_trigger orig_action
  orig_trigger=$(yq '.trigger // ""' "$ifile" 2>/dev/null || echo "")
  orig_action=$(yq '.action // ""' "$ifile" 2>/dev/null || echo "")

  local sf="$STAGING_DIR/${cid}.yaml"
  cat > "$sf" <<YAML
version: 1
cid: ${cid}
entry_type: instinct
scope: ${SCOPE}
project_id: "${PROJECT_ID}"
source_id: ${sid}
orig_trigger: "$(yaml_escape_dq "$orig_trigger")"
orig_action: "$(yaml_escape_dq "$orig_action")"
compressed_trigger: "$(yaml_escape_dq "$trigger")"
compressed_action: "$(yaml_escape_dq "$action")"
created: "${NOW}"
status: pending
YAML
  mark_seen "$sid"
  _PASS_STAGED=$((_PASS_STAGED + 1)); TOTAL_STAGED=$((TOTAL_STAGED + 1))
  emit "staged ${cid} (instinct): ${sid}"
}

compress_instincts() {
  reset_pass
  clear_staging "instinct"
  local index="$BASE_DIR/instincts/index.yaml" idir="$BASE_DIR/instincts"
  [[ -f "$index" ]] || return 0

  if ! acquire_lock_blocking "$LOCK_FILE" 15; then
    emit "instinct pass: lock busy, skipped (retry shortly)"; return 0
  fi
  local total cand_yaml="" cand_count=0 i iid trig act combined
  total=$(yq '.instincts | length' "$index" 2>/dev/null || echo 0)
  for ((i=0; i<total; i++)); do
    iid=$(yq ".instincts[$i].id" "$index" 2>/dev/null || echo "")
    [[ -z "$iid" ]] && continue
    [[ -f "$idir/${iid}.yaml" ]] || continue
    trig=$(yq '.trigger // ""' "$idir/${iid}.yaml" 2>/dev/null || echo "")
    act=$(yq '.action // ""' "$idir/${iid}.yaml" 2>/dev/null || echo "")
    # Length pre-filter: skip instincts already terser than the threshold.
    combined=$(( ${#trig} + ${#act} ))
    [[ "$combined" -le "$MIN_INSTINCT_CHARS" ]] && continue
    cand_yaml+="$(cat "$idir/${iid}.yaml")"$'\n---\n'
    cand_count=$((cand_count + 1))
  done
  release_lock "$LOCK_FILE"

  if [[ "$cand_count" -eq 0 ]]; then
    evolve_log "compress.sh(instinct): no over-threshold candidates"; return 0
  fi

  local input="## Candidate Instincts"$'\n\n'"$cand_yaml"
  local out
  out=$(invoke_compressor "compressor-instinct" "$input") || { evolve_log "compress.sh(instinct): nothing compressed"; return 0; }
  split_docs "$out" process_instinct_doc
  return 0
}

# ── Memory pass ──────────────────────────────────────────────────────────────
process_memory_doc() {
  local doc="$1" tmp
  doc=$(printf '%s' "$doc" | sed '/^```yaml$/d; /^```$/d')
  tmp=$(mktemp)
  printf '%s' "$doc" > "$tmp"

  local sid title description content_file
  sid=$(yq_field '.source_id' "$tmp")
  title=$(yq_field '.compressed_title' "$tmp")
  description=$(yq_field '.compressed_description' "$tmp")
  content_file=$(mktemp)
  yq '.compressed_content // ""' "$tmp" > "$content_file" 2>/dev/null || : > "$content_file"
  rm -f "$tmp"

  if [[ "$_PASS_STAGED" -ge "$MAX_PER_RUN" ]]; then rm -f "$content_file"; return; fi
  if [[ -z "$sid" || -z "$title" || ! -s "$content_file" ]]; then
    evolve_log "compress.sh(memory): skip doc (sid=$sid)"; rm -f "$content_file"; return
  fi

  local mindex="$BASE_DIR/memory/index.yaml" mdir="$BASE_DIR/memory" present mfile
  present=$(yq "[.memories[] | select(.id == \"$sid\")] | length" "$mindex" 2>/dev/null || echo 0)
  if [[ "$present" -eq 0 ]]; then evolve_log "compress.sh(memory): skip -- '$sid' not in index"; rm -f "$content_file"; return; fi
  if any_seen "$sid"; then evolve_log "compress.sh(memory): skip -- '$sid' already staged"; rm -f "$content_file"; return; fi
  mfile=$(yq ".memories[] | select(.id == \"$sid\") | .file" "$mindex" 2>/dev/null || echo "")
  if [[ -z "$mfile" || ! -f "$mdir/$mfile" ]]; then evolve_log "compress.sh(memory): skip -- body missing for '$sid'"; rm -f "$content_file"; return; fi

  local cid="compression-memory-${sid}-${EPOCH_NOW}"
  if [[ "${#cid}" -gt 128 ]]; then evolve_log "compress.sh(memory): skip -- cid too long for '$sid'"; rm -f "$content_file"; return; fi

  local orig_title orig_description orig_sha content
  orig_title=$(yq ".memories[] | select(.id == \"$sid\") | .title // \"\"" "$mindex" 2>/dev/null || echo "")
  orig_description=$(yq ".memories[] | select(.id == \"$sid\") | .description // \"\"" "$mindex" 2>/dev/null || echo "")
  orig_sha=$(sha_of "$mdir/$mfile")
  content=$(cat "$content_file"); rm -f "$content_file"

  local sf="$STAGING_DIR/${cid}.yaml"
  cat > "$sf" <<YAML
version: 1
cid: ${cid}
entry_type: memory
scope: ${SCOPE}
project_id: "${PROJECT_ID}"
source_id: ${sid}
orig_title: "$(yaml_escape_dq "$orig_title")"
orig_description: "$(yaml_escape_dq "$orig_description")"
orig_content_sha: "${orig_sha}"
compressed_title: "$(yaml_escape_dq "$title")"
compressed_description: "$(yaml_escape_dq "$description")"
compressed_content: |
$(printf '%s\n' "$content" | sed 's/^/  /')
created: "${NOW}"
status: pending
YAML
  mark_seen "$sid"
  _PASS_STAGED=$((_PASS_STAGED + 1)); TOTAL_STAGED=$((TOTAL_STAGED + 1))
  emit "staged ${cid} (memory): ${sid}"
}

compress_memories() {
  reset_pass
  clear_staging "memory"
  local mindex="$BASE_DIR/memory/index.yaml" mdir="$BASE_DIR/memory"
  [[ -f "$mindex" ]] || return 0

  if ! acquire_lock_blocking "$LOCK_FILE" 15; then
    emit "memory pass: lock busy, skipped (retry shortly)"; return 0
  fi
  local total mcount=0 input="## Candidate Memories"$'\n\n' i mid mfile mtitle mdesc mbody
  total=$(yq '.memories | length' "$mindex" 2>/dev/null || echo 0)
  for ((i=0; i<total; i++)); do
    mid=$(yq ".memories[$i].id" "$mindex" 2>/dev/null || echo "")
    mfile=$(yq ".memories[$i].file" "$mindex" 2>/dev/null || echo "")
    mtitle=$(yq ".memories[$i].title // \"\"" "$mindex" 2>/dev/null || echo "")
    mdesc=$(yq ".memories[$i].description // \"\"" "$mindex" 2>/dev/null || echo "")
    [[ -z "$mid" || -z "$mfile" || ! -f "$mdir/$mfile" ]] && continue
    mbody=$(cat "$mdir/$mfile")
    # Length pre-filter: skip memory bodies already terser than the threshold.
    [[ "${#mbody}" -le "$MIN_MEMORY_CHARS" ]] && continue
    input+="### ${mid}"$'\n'"title: ${mtitle}"$'\n'"description: ${mdesc}"$'\n'"---body---"$'\n'"${mbody}"$'\n\n'
    mcount=$((mcount + 1))
  done
  release_lock "$LOCK_FILE"

  if [[ "$mcount" -eq 0 ]]; then
    evolve_log "compress.sh(memory): no over-threshold candidates"; return 0
  fi
  local out
  out=$(invoke_compressor "compressor-memory" "$input") || { evolve_log "compress.sh(memory): nothing compressed"; return 0; }
  split_docs "$out" process_memory_doc
  return 0
}

# When sourced by the hermetic test harness, stop here (functions are defined;
# the passes are not run).
if [[ "${EVOLVE_COMPRESS_LIB:-}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

# ── Arguments / scope ────────────────────────────────────────────────────────
SCOPE="project"
PROJECT_ID=""
if [[ "${1:-}" == "--global" ]]; then
  SCOPE="global"
elif [[ -n "${1:-}" ]]; then
  PROJECT_ID="$1"
else
  echo "usage: compress.sh <project_id> | --global" >&2
  exit 1
fi

# Never run inside an evolve agent subprocess (recursion guard).
if evolve_is_subprocess; then
  exit 0
fi

if ! evolve_enabled; then
  emit "evolve is disabled (observer.enabled=false); nothing to do"
  exit 0
fi

# ── Paths + config ───────────────────────────────────────────────────────────
if [[ "$SCOPE" == "global" ]]; then
  init_global
  BASE_DIR="$GLOBAL_DIR"
  LOCK_FILE="$GLOBAL_DIR/global.lock"
  CONF_PID=""
  STAGING_DIR="$EVOLVE_DIR/compressions/global"
  TARGET_LABEL="global"
else
  if ! validate_project_id "$PROJECT_ID"; then
    echo "compress.sh: invalid project id '$PROJECT_ID'" >&2
    exit 1
  fi
  init_project "$PROJECT_ID"
  BASE_DIR="$EVOLVE_DIR/projects/$PROJECT_ID"
  LOCK_FILE="$BASE_DIR/evolve.lock"
  CONF_PID="$PROJECT_ID"
  STAGING_DIR="$EVOLVE_DIR/compressions/$PROJECT_ID"
  TARGET_LABEL="$PROJECT_ID"
fi
mkdir -p "$STAGING_DIR"

AGENT_MODEL=$(read_config '.compression.agent_model // "claude-sonnet-4-6"' "$CONF_PID" 2>/dev/null || echo "claude-sonnet-4-6")
[[ -n "$AGENT_MODEL" ]] || AGENT_MODEL="claude-sonnet-4-6"
MAX_PER_RUN=$(read_config '.compression.max_per_run // 25' "$CONF_PID" 2>/dev/null || echo "25")
MAX_PER_RUN=$(validate_numeric "$MAX_PER_RUN" "$_NUMERIC_NONNEG_INT" "25")
MIN_INSTINCT_CHARS=$(read_config '.compression.min_instinct_chars // 160' "$CONF_PID" 2>/dev/null || echo "160")
MIN_INSTINCT_CHARS=$(validate_numeric "$MIN_INSTINCT_CHARS" "$_NUMERIC_NONNEG_INT" "160")
MIN_MEMORY_CHARS=$(read_config '.compression.min_memory_chars // 320' "$CONF_PID" 2>/dev/null || echo "320")
MIN_MEMORY_CHARS=$(validate_numeric "$MIN_MEMORY_CHARS" "$_NUMERIC_NONNEG_INT" "320")

EPOCH_NOW=$(date -u +%s)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TOTAL_STAGED=0

# Release any held lock on any exit.
trap 'release_lock "$LOCK_FILE" 2>/dev/null' EXIT

# ── Run passes ───────────────────────────────────────────────────────────────
compress_instincts
compress_memories

if [[ "$TOTAL_STAGED" -eq 0 ]]; then
  emit "no compression candidates for ${TARGET_LABEL}"
else
  emit "staged ${TOTAL_STAGED} compression(s) for ${TARGET_LABEL} in ${STAGING_DIR}"
fi
exit 0
