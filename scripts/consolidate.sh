#!/usr/bin/env bash
set -euo pipefail

# consolidate.sh <project_id> | --global
#
# ANALYSIS ONLY. Detects redundant instincts/memories and related pending
# skill/rule proposals, asks a consolidator agent to merge each group, and
# writes one *staging* file per proposed merge under
#   $EVOLVE_DIR/consolidations/<project_id>/   (project scope)
#   $EVOLVE_DIR/consolidations/global/         (global scope)
# It NEVER mutates instincts/memories/proposals and NEVER git-pushes. The
# /consolidate skill presents the staged merges; apply-consolidation.sh applies
# an approved one; discard-consolidation.sh drops a rejected one.
#
# Staging lives OUTSIDE data/ so evolve_git_push (git add data/...) never
# commits this transient per-machine working state.
#
# Sourcing with EVOLVE_CONSOLIDATE_LIB=1 defines the functions but does not run
# the passes (used by the hermetic parser test).

source "$HOME/.claude/evolve/scripts/lib.sh"

# User-invoked (via skill): surface failures, do not silently exit 0.
trap 'evolve_log "ERROR ${BASH_SOURCE[0]##*/}:$LINENO (exit $?)"' ERR

emit() { evolve_log "consolidate.sh: $*"; echo "$*"; }

# ── Generic helpers ──────────────────────────────────────────────────────────

# clear_staging <entry_type> -- remove this scope's prior pending staging for a
# pass so a fresh analysis run supersedes it (staged merges are recomputable).
clear_staging() {
  local et="$1" f
  for f in "$STAGING_DIR"/consolidation-"$et"-*.yaml; do
    if [[ -e "$f" ]]; then rm -f "$f"; fi
  done
  return 0
}

# invoke_consolidator <agent_basename> <input> -- substitutes {min_group_size},
# runs the agent with the configured model, prints raw output. Returns 1 on
# invocation failure or a NONE/empty result.
invoke_consolidator() {
  local agent_base="$1" input="$2" out trimmed
  AGENT_TMP=$(mktemp)
  sed "s/{min_group_size}/$MIN_GROUP_SIZE/g" "$EVOLVE_DIR/agents/${agent_base}.md" > "$AGENT_TMP"
  out=$(printf '%s\n' "$input" | EVOLVE_AGENT_MODEL_OVERRIDE="$AGENT_MODEL" invoke_agent "$AGENT_TMP" 2>/dev/null) || {
    rm -f "$AGENT_TMP"; AGENT_TMP=""
    evolve_log "consolidate.sh: agent $agent_base invocation failed"
    return 1
  }
  rm -f "$AGENT_TMP"; AGENT_TMP=""
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

# read_list <tmp_doc> <path> -- newline-separated list from a YAML sequence.
read_list() {
  local doc="$1" path="$2" n i out=""
  n=$(yq "$path | length" "$doc" 2>/dev/null || echo "0")
  for ((i=0; i<n; i++)); do
    out+="$(yq "${path}[$i]" "$doc" 2>/dev/null || echo "")"$'\n'
  done
  printf '%s' "$out"
}

# name_ok <name> [is_memory] -- kebab, <=45 chars; memory also forbids global-
# prefix and a trailing -YYYY-MM-DD date suffix.
name_ok() {
  local name="$1" is_mem="${2:-0}"
  validate_id "$name" || return 1
  [[ "${#name}" -le 45 ]] || return 1
  if [[ "$is_mem" -eq 1 ]]; then
    [[ "$name" == global-* ]] && return 1
    [[ "$name" =~ -[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && return 1
  fi
  return 0
}

# ── Per-pass state (reset at the start of each pass) ─────────────────────────
_SEEN=""        # newline-separated source ids already claimed in this pass
_PASS_STAGED=0

reset_pass() { _SEEN=""; _PASS_STAGED=0; }

# any_seen <newline_ids> -- returns 0 if any id is already claimed this pass.
any_seen() {
  local ids="$1" id
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if printf '%s\n' "$_SEEN" | grep -qx "$id"; then return 0; fi
  done <<< "$ids"
  return 1
}

mark_seen() {
  local ids="$1" id
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    _SEEN+="$id"$'\n'
  done <<< "$ids"
}

# ── Instinct pass ────────────────────────────────────────────────────────────
process_instinct_doc() {
  local doc="$1" tmp
  doc=$(printf '%s' "$doc" | sed '/^```yaml$/d; /^```$/d')
  tmp=$(mktemp)
  printf '%s' "$doc" > "$tmp"

  local name trigger action domain src_raw src_count
  src_raw=$(read_list "$tmp" '.source_instincts')
  src_count=$(printf '%s' "$src_raw" | grep -c . || true)
  name=$(yq_field '.merged_name' "$tmp")
  trigger=$(yq_field '.merged_trigger' "$tmp")
  action=$(yq_field '.merged_action' "$tmp")
  domain=$(yq_field '.merged_domain' "$tmp")
  rm -f "$tmp"

  [[ "$_PASS_STAGED" -ge "$MAX_PER_RUN" ]] && return
  if [[ -z "$name" || -z "$trigger" || -z "$action" || "$src_count" -lt "$MIN_GROUP_SIZE" ]]; then
    evolve_log "consolidate.sh(instinct): skip group (name=$name, count=$src_count)"; return
  fi
  if ! name_ok "$name" 0; then
    evolve_log "consolidate.sh(instinct): skip invalid merged_name='$name'"; return
  fi
  # domain: agent value if a valid id, else the highest-confidence source's domain.
  if ! validate_id "$domain"; then domain=""; fi

  local idir="$BASE_DIR/instincts" sid
  while IFS= read -r sid; do
    [[ -z "$sid" ]] && continue
    if ! validate_id "$sid"; then evolve_log "consolidate.sh(instinct): skip bad source id '$sid'"; return; fi
    if [[ "$sid" == "$name" ]]; then evolve_log "consolidate.sh(instinct): skip -- merged_name equals source '$sid'"; return; fi
    if [[ ! -f "$idir/${sid}.yaml" ]]; then evolve_log "consolidate.sh(instinct): skip -- source '$sid' not in snapshot"; return; fi
  done <<< "$src_raw"

  if [[ -f "$idir/${name}.yaml" || -f "$idir/archived/${name}.yaml" ]]; then
    evolve_log "consolidate.sh(instinct): skip -- '$name' already exists"; return
  fi
  if any_seen "$src_raw"; then evolve_log "consolidate.sh(instinct): skip -- overlaps a prior group"; return; fi

  if [[ -z "$domain" ]]; then
    local first="${src_raw%%$'\n'*}"
    domain=$(yq '.domain // "unknown"' "$idir/${first}.yaml" 2>/dev/null || echo "unknown")
    validate_id "$domain" || domain="unknown"
  fi

  local cid="consolidation-instinct-${name}-${EPOCH_NOW}"
  local sf="$STAGING_DIR/${cid}.yaml"
  local src_yaml=""
  while IFS= read -r sid; do [[ -z "$sid" ]] && continue; src_yaml+="  - $sid"$'\n'; done <<< "$src_raw"
  cat > "$sf" <<YAML
version: 1
cid: ${cid}
entry_type: instinct
scope: ${SCOPE}
project_id: "${PROJECT_ID}"
source_ids:
${src_yaml}merged_name: ${name}
merged_domain: ${domain}
merged_trigger: "$(yaml_escape_dq "$trigger")"
merged_action: "$(yaml_escape_dq "$action")"
created: "${NOW}"
status: pending
YAML
  mark_seen "$src_raw"
  _PASS_STAGED=$((_PASS_STAGED + 1)); TOTAL_STAGED=$((TOTAL_STAGED + 1))
  emit "staged ${cid} (instinct): merges ${src_count} instincts -> ${name}"
}

consolidate_instincts() {
  reset_pass
  clear_staging "instinct"
  local index="$BASE_DIR/instincts/index.yaml" idir="$BASE_DIR/instincts"
  [[ -f "$index" ]] || return 0

  if ! acquire_lock_blocking "$LOCK_FILE" 15; then
    emit "instinct pass: lock busy, skipped (retry shortly)"; return 0
  fi

  # Instinct ids referenced by pending proposals (project source_instincts and
  # global-memory source_global_instincts) are excluded -- they are already
  # owned by the clustering/graduation pipeline.
  local pindex="$BASE_DIR/proposals/index.yaml" pending_ids="" pcount pf pp
  if [[ -f "$pindex" ]]; then
    pcount=$(yq '.proposals | length' "$pindex" 2>/dev/null || echo 0)
    local pi j jn
    for ((pi=0; pi<pcount; pi++)); do
      pf=$(yq ".proposals[$pi].file" "$pindex" 2>/dev/null || echo "")
      pp="$BASE_DIR/proposals/$pf"
      [[ -f "$pp" ]] || continue
      jn=$(yq '.source_instincts | length' "$pp" 2>/dev/null || echo 0)
      for ((j=0; j<jn; j++)); do pending_ids+="$(yq ".source_instincts[$j]" "$pp")"$'\n'; done
      jn=$(yq '.source_global_instincts | length' "$pp" 2>/dev/null || echo 0)
      for ((j=0; j<jn; j++)); do pending_ids+="$(yq ".source_global_instincts[$j]" "$pp")"$'\n'; done
    done
  fi

  local total cand_yaml="" cand_count=0 i conf iid ge lt
  total=$(yq '.instincts | length' "$index" 2>/dev/null || echo 0)
  for ((i=0; i<total; i++)); do
    conf=$(yq ".instincts[$i].confidence" "$index" 2>/dev/null || echo "0")
    conf=$(validate_numeric "$conf" "$_NUMERIC_NONNEG_FLOAT" "0")
    # Band filter [min_confidence, propose_memory_threshold). Two single bc
    # comparisons (BSD bc has no && operator; matches the rest of the codebase).
    ge=$(echo "$conf >= $MIN_CONFIDENCE" | bc -l)
    lt=$(echo "$conf < $PROPOSE_MEM_THRESHOLD" | bc -l)
    if [[ "$ge" != "1" || "$lt" != "1" ]]; then continue; fi
    iid=$(yq ".instincts[$i].id" "$index" 2>/dev/null || echo "")
    [[ -z "$iid" ]] && continue
    if printf '%s\n' "$pending_ids" | grep -qx "$iid"; then continue; fi
    [[ -f "$idir/${iid}.yaml" ]] || continue
    cand_yaml+="$(cat "$idir/${iid}.yaml")"$'\n---\n'
    cand_count=$((cand_count + 1))
  done
  release_lock "$LOCK_FILE"

  if [[ "$cand_count" -lt "$MIN_GROUP_SIZE" ]]; then
    evolve_log "consolidate.sh(instinct): only $cand_count in-band candidates; skipping"
    return 0
  fi

  local input="## Candidate Instincts"$'\n\n'"$cand_yaml"
  local out
  out=$(invoke_consolidator "consolidator-instinct" "$input") || { evolve_log "consolidate.sh(instinct): no merges"; return 0; }
  split_docs "$out" process_instinct_doc
  return 0
}

# ── Memory pass ──────────────────────────────────────────────────────────────
process_memory_doc() {
  local doc="$1" tmp
  doc=$(printf '%s' "$doc" | sed '/^```yaml$/d; /^```$/d')
  tmp=$(mktemp)
  printf '%s' "$doc" > "$tmp"

  local name title description content src_raw src_count content_file
  src_raw=$(read_list "$tmp" '.source_ids')
  src_count=$(printf '%s' "$src_raw" | grep -c . || true)
  name=$(yq_field '.merged_name' "$tmp")
  title=$(yq_field '.merged_title' "$tmp")
  description=$(yq_field '.merged_description' "$tmp")
  content_file=$(mktemp)
  yq '.merged_content // ""' "$tmp" > "$content_file" 2>/dev/null || : > "$content_file"
  rm -f "$tmp"

  if [[ "$_PASS_STAGED" -ge "$MAX_PER_RUN" ]]; then rm -f "$content_file"; return; fi
  if [[ -z "$name" || -z "$title" || ! -s "$content_file" || "$src_count" -lt "$MIN_GROUP_SIZE" ]]; then
    evolve_log "consolidate.sh(memory): skip group (name=$name, count=$src_count)"; rm -f "$content_file"; return
  fi
  if ! name_ok "$name" 1; then evolve_log "consolidate.sh(memory): skip invalid merged_name='$name'"; rm -f "$content_file"; return; fi

  local mindex="$BASE_DIR/memory/index.yaml" mdir="$BASE_DIR/memory" sid
  while IFS= read -r sid; do
    [[ -z "$sid" ]] && continue
    if [[ "$sid" == "$name" ]]; then evolve_log "consolidate.sh(memory): skip -- name equals source '$sid'"; rm -f "$content_file"; return; fi
    local present
    present=$(yq "[.memories[] | select(.id == \"$sid\")] | length" "$mindex" 2>/dev/null || echo 0)
    if [[ "$present" -eq 0 ]]; then evolve_log "consolidate.sh(memory): skip -- source '$sid' not in index"; rm -f "$content_file"; return; fi
  done <<< "$src_raw"

  local mem_id="${MEM_PREFIX}${name}"
  local existing
  existing=$(yq "[.memories[] | select(.id == \"$mem_id\")] | length" "$mindex" 2>/dev/null || echo 0)
  if [[ "$existing" -ne 0 || -f "$mdir/${mem_id}.md" || -f "$mdir/archived/${mem_id}.md" ]]; then
    evolve_log "consolidate.sh(memory): skip -- '$mem_id' already exists"; rm -f "$content_file"; return
  fi
  if any_seen "$src_raw"; then evolve_log "consolidate.sh(memory): skip -- overlaps a prior group"; rm -f "$content_file"; return; fi

  content=$(cat "$content_file"); rm -f "$content_file"
  local cid="consolidation-memory-${name}-${EPOCH_NOW}"
  local sf="$STAGING_DIR/${cid}.yaml"
  local src_yaml=""
  while IFS= read -r sid; do [[ -z "$sid" ]] && continue; src_yaml+="  - $sid"$'\n'; done <<< "$src_raw"
  cat > "$sf" <<YAML
version: 1
cid: ${cid}
entry_type: memory
scope: ${SCOPE}
project_id: "${PROJECT_ID}"
source_ids:
${src_yaml}merged_name: ${name}
merged_title: "$(yaml_escape_dq "$title")"
merged_description: "$(yaml_escape_dq "$description")"
merged_content: |
$(printf '%s\n' "$content" | sed 's/^/  /')
created: "${NOW}"
status: pending
YAML
  mark_seen "$src_raw"
  _PASS_STAGED=$((_PASS_STAGED + 1)); TOTAL_STAGED=$((TOTAL_STAGED + 1))
  emit "staged ${cid} (memory): merges ${src_count} memories -> ${name}"
}

consolidate_memories() {
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
    input+="### ${mid}"$'\n'"title: ${mtitle}"$'\n'"description: ${mdesc}"$'\n'"---body---"$'\n'"${mbody}"$'\n\n'
    mcount=$((mcount + 1))
  done
  release_lock "$LOCK_FILE"

  if [[ "$mcount" -lt "$MIN_GROUP_SIZE" ]]; then
    evolve_log "consolidate.sh(memory): only $mcount candidates; skipping"
    return 0
  fi
  local out
  out=$(invoke_consolidator "consolidator-memory" "$input") || { evolve_log "consolidate.sh(memory): no merges"; return 0; }
  split_docs "$out" process_memory_doc
  return 0
}

# ── Proposal pass (project scope only; skill/rule types only) ────────────────
process_proposal_doc() {
  local doc="$1" tmp
  doc=$(printf '%s' "$doc" | sed '/^```yaml$/d; /^```$/d')
  tmp=$(mktemp)
  printf '%s' "$doc" > "$tmp"

  local name mtype title description src_raw src_count content_file
  src_raw=$(read_list "$tmp" '.source_proposals')
  src_count=$(printf '%s' "$src_raw" | grep -c . || true)
  name=$(yq_field '.merged_name' "$tmp")
  mtype=$(yq_field '.merged_type' "$tmp")
  title=$(yq_field '.merged_title' "$tmp")
  description=$(yq_field '.merged_description' "$tmp")
  content_file=$(mktemp)
  yq '.merged_proposed_content // ""' "$tmp" > "$content_file" 2>/dev/null || : > "$content_file"
  rm -f "$tmp"

  if [[ "$_PASS_STAGED" -ge "$MAX_PER_RUN" ]]; then rm -f "$content_file"; return; fi
  if [[ -z "$name" || -z "$mtype" || ! -s "$content_file" || "$src_count" -lt "$MIN_GROUP_SIZE" ]]; then
    evolve_log "consolidate.sh(proposal): skip group (name=$name, count=$src_count)"; rm -f "$content_file"; return
  fi
  if [[ "$mtype" != "skill" && "$mtype" != "rule" ]]; then
    evolve_log "consolidate.sh(proposal): skip non skill/rule type='$mtype'"; rm -f "$content_file"; return
  fi
  if ! name_ok "$name" 0; then evolve_log "consolidate.sh(proposal): skip invalid merged_name='$name'"; rm -f "$content_file"; return; fi

  local pindex="$BASE_DIR/proposals/index.yaml" pdir="$BASE_DIR/proposals" sid
  local union="" spf spp stype jn j si
  while IFS= read -r sid; do
    [[ -z "$sid" ]] && continue
    if [[ "$sid" == "$name" ]]; then evolve_log "consolidate.sh(proposal): skip -- name equals source '$sid'"; rm -f "$content_file"; return; fi
    spf=$(yq ".proposals[] | select(.id == \"$sid\") | .file" "$pindex" 2>/dev/null || echo "")
    if [[ -z "$spf" ]]; then evolve_log "consolidate.sh(proposal): skip -- source '$sid' not pending"; rm -f "$content_file"; return; fi
    spp="$pdir/$spf"
    [[ -f "$spp" ]] || { evolve_log "consolidate.sh(proposal): skip -- file missing for '$sid'"; rm -f "$content_file"; return; }
    stype=$(yq '.type // ""' "$spp" 2>/dev/null || echo "")
    if [[ "$stype" != "$mtype" ]]; then evolve_log "consolidate.sh(proposal): skip -- '$sid' type '$stype' != '$mtype'"; rm -f "$content_file"; return; fi
    jn=$(yq '.source_instincts | length' "$spp" 2>/dev/null || echo 0)
    for ((j=0; j<jn; j++)); do union+="$(yq ".source_instincts[$j]" "$spp")"$'\n'; done
  done <<< "$src_raw"

  if [[ -f "$pdir/${name}-${mtype}.yaml" ]]; then
    evolve_log "consolidate.sh(proposal): skip -- '${name}-${mtype}.yaml' already exists"; rm -f "$content_file"; return
  fi
  if any_seen "$src_raw"; then evolve_log "consolidate.sh(proposal): skip -- overlaps a prior group"; rm -f "$content_file"; return; fi

  local content; content=$(cat "$content_file"); rm -f "$content_file"
  local union_uniq; union_uniq=$(printf '%s' "$union" | grep -v '^$' | sort -u || true)
  local union_count; union_count=$(printf '%s' "$union_uniq" | grep -c . || true)

  local cid="consolidation-proposal-${name}-${EPOCH_NOW}"
  local sf="$STAGING_DIR/${cid}.yaml"
  local src_yaml="" inst_yaml=""
  while IFS= read -r sid; do [[ -z "$sid" ]] && continue; src_yaml+="  - $sid"$'\n'; done <<< "$src_raw"
  while IFS= read -r si; do [[ -z "$si" ]] && continue; inst_yaml+="  - $si"$'\n'; done <<< "$union_uniq"
  cat > "$sf" <<YAML
version: 1
cid: ${cid}
entry_type: proposal
scope: ${SCOPE}
project_id: "${PROJECT_ID}"
source_ids:
${src_yaml}merged_name: ${name}
merged_type: ${mtype}
merged_title: "$(yaml_escape_dq "$title")"
merged_description: "$(yaml_escape_dq "$description")"
merged_source_instincts:
${inst_yaml}merged_source_instinct_count: ${union_count}
merged_proposed_content: |
$(printf '%s\n' "$content" | sed 's/^/  /')
created: "${NOW}"
status: pending
YAML
  mark_seen "$src_raw"
  _PASS_STAGED=$((_PASS_STAGED + 1)); TOTAL_STAGED=$((TOTAL_STAGED + 1))
  emit "staged ${cid} (proposal): merges ${src_count} ${mtype} proposals -> ${name}"
}

consolidate_proposals() {
  [[ "$SCOPE" == "project" ]] || return 0
  reset_pass
  clear_staging "proposal"
  local pindex="$BASE_DIR/proposals/index.yaml" pdir="$BASE_DIR/proposals"
  [[ -f "$pindex" ]] || return 0

  if ! acquire_lock_blocking "$LOCK_FILE" 15; then
    emit "proposal pass: lock busy, skipped (retry shortly)"; return 0
  fi
  local total pcount=0 input="## Candidate Proposals"$'\n\n' i pid pfile ptype ptitle pdesc pcontent
  total=$(yq '.proposals | length' "$pindex" 2>/dev/null || echo 0)
  for ((i=0; i<total; i++)); do
    pid=$(yq ".proposals[$i].id" "$pindex" 2>/dev/null || echo "")
    ptype=$(yq ".proposals[$i].type" "$pindex" 2>/dev/null || echo "")
    pfile=$(yq ".proposals[$i].file" "$pindex" 2>/dev/null || echo "")
    [[ "$ptype" == "skill" || "$ptype" == "rule" ]] || continue
    [[ -z "$pid" || -z "$pfile" || ! -f "$pdir/$pfile" ]] && continue
    ptitle=$(yq '.title // ""' "$pdir/$pfile" 2>/dev/null || echo "")
    pdesc=$(yq '.description // ""' "$pdir/$pfile" 2>/dev/null || echo "")
    pcontent=$(yq '.proposed_content // ""' "$pdir/$pfile" 2>/dev/null || echo "")
    input+="### ${pid}"$'\n'"type: ${ptype}"$'\n'"title: ${ptitle}"$'\n'"description: ${pdesc}"$'\n'"---content---"$'\n'"${pcontent}"$'\n\n'
    pcount=$((pcount + 1))
  done
  release_lock "$LOCK_FILE"

  if [[ "$pcount" -lt "$MIN_GROUP_SIZE" ]]; then
    evolve_log "consolidate.sh(proposal): only $pcount skill/rule candidates; skipping"
    return 0
  fi
  local out
  out=$(invoke_consolidator "consolidator-proposal" "$input") || { evolve_log "consolidate.sh(proposal): no merges"; return 0; }
  split_docs "$out" process_proposal_doc
  return 0
}

# When sourced by the hermetic test harness, stop here (functions are defined;
# the passes are not run).
if [[ "${EVOLVE_CONSOLIDATE_LIB:-}" == "1" ]]; then
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
  echo "usage: consolidate.sh <project_id> | --global" >&2
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
  MEM_PREFIX="global-"
  PROP_THRESH_PATH='.global_instincts.propose_memory_threshold // 0.85'
  STAGING_DIR="$EVOLVE_DIR/consolidations/global"
  TARGET_LABEL="global"
else
  if ! validate_id "$PROJECT_ID"; then
    echo "consolidate.sh: invalid project id '$PROJECT_ID'" >&2
    exit 1
  fi
  init_project "$PROJECT_ID"
  BASE_DIR="$EVOLVE_DIR/projects/$PROJECT_ID"
  LOCK_FILE="$BASE_DIR/evolve.lock"
  CONF_PID="$PROJECT_ID"
  MEM_PREFIX=""
  PROP_THRESH_PATH='.instincts.propose_memory_threshold // 0.85'
  STAGING_DIR="$EVOLVE_DIR/consolidations/$PROJECT_ID"
  TARGET_LABEL="$PROJECT_ID"
fi
mkdir -p "$STAGING_DIR"

AGENT_MODEL=$(read_config '.consolidation.agent_model // "claude-sonnet-4-6"' "$CONF_PID" 2>/dev/null || echo "claude-sonnet-4-6")
[[ -n "$AGENT_MODEL" ]] || AGENT_MODEL="claude-sonnet-4-6"
MIN_CONFIDENCE=$(read_config '.consolidation.min_confidence // 0.5' "$CONF_PID" 2>/dev/null || echo "0.5")
MIN_CONFIDENCE=$(validate_numeric "$MIN_CONFIDENCE" "$_NUMERIC_NONNEG_FLOAT" "0.5")
MIN_GROUP_SIZE=$(read_config '.consolidation.min_group_size // 2' "$CONF_PID" 2>/dev/null || echo "2")
MIN_GROUP_SIZE=$(validate_numeric "$MIN_GROUP_SIZE" "$_NUMERIC_NONNEG_INT" "2")
MAX_PER_RUN=$(read_config '.consolidation.max_per_run // 10' "$CONF_PID" 2>/dev/null || echo "10")
MAX_PER_RUN=$(validate_numeric "$MAX_PER_RUN" "$_NUMERIC_NONNEG_INT" "10")
PROPOSE_MEM_THRESHOLD=$(read_config "$PROP_THRESH_PATH" "$CONF_PID" 2>/dev/null || echo "0.85")
PROPOSE_MEM_THRESHOLD=$(validate_numeric "$PROPOSE_MEM_THRESHOLD" "$_NUMERIC_NONNEG_FLOAT" "0.85")

EPOCH_NOW=$(date -u +%s)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
AGENT_TMP=""
TOTAL_STAGED=0

# Release any held lock and clean the agent tempfile on any exit.
trap 'release_lock "$LOCK_FILE" 2>/dev/null; [[ -n "$AGENT_TMP" ]] && rm -f "$AGENT_TMP"' EXIT

# ── Run passes ───────────────────────────────────────────────────────────────
consolidate_instincts
consolidate_memories
consolidate_proposals

if [[ "$TOTAL_STAGED" -eq 0 ]]; then
  emit "no consolidation candidates for ${TARGET_LABEL}"
else
  emit "staged ${TOTAL_STAGED} consolidation(s) for ${TARGET_LABEL} in ${STAGING_DIR}"
fi
exit 0
