#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$HOME/.claude/evolve/scripts/lib.sh"

# Trap errors -- log and exit 0 (never block Claude; this IS a hook script via observe.sh)
trap 'evolve_trap $LINENO $?' ERR

# Recursive hook prevention
evolve_is_subprocess && exit 0

# ── Arguments ──────────────────────────────────────────────────────────────
PROJECT_ID="${1:?graduate.sh requires PROJECT_ID as \$1}"

if ! validate_id "$PROJECT_ID"; then
  evolve_log "graduate.sh: invalid PROJECT_ID '$PROJECT_ID'"
  exit 0
fi

# Defensive init: existing users on the upgrade path may not have re-run install.sh.
init_project "$PROJECT_ID" 2>/dev/null || true
init_global 2>/dev/null || true

# ── Paths ──────────────────────────────────────────────────────────────────
PROJECT_DIR="$EVOLVE_DIR/projects/$PROJECT_ID"
INSTINCTS_DIR="$PROJECT_DIR/instincts"
INSTINCTS_INDEX="$INSTINCTS_DIR/index.yaml"
PROPOSALS_DIR="$PROJECT_DIR/proposals"
PROPOSAL_INDEX="$PROPOSALS_DIR/index.yaml"
PROPOSAL_ARCHIVED_DIR="$PROPOSALS_DIR/archived"
PROPOSAL_ARCHIVED_INDEX="$PROPOSAL_ARCHIVED_DIR/index.yaml"
LOCK_FILE="$PROJECT_DIR/evolve.lock"
SIDECAR="$INSTINCTS_DIR/.graduate-state.yaml"
WARN_FILE="$PROJECT_DIR/.graduation-warning"

GLOBAL_INSTINCTS_DIR="$GLOBAL_DIR/instincts"
GLOBAL_INSTINCTS_INDEX="$GLOBAL_INSTINCTS_DIR/index.yaml"
GLOBAL_PROPOSALS_DIR="$GLOBAL_DIR/proposals"
GLOBAL_PROPOSAL_INDEX="$GLOBAL_PROPOSALS_DIR/index.yaml"
GLOBAL_PROPOSAL_ARCHIVED_DIR="$GLOBAL_PROPOSALS_DIR/archived"
GLOBAL_PROPOSAL_ARCHIVED_INDEX="$GLOBAL_PROPOSAL_ARCHIVED_DIR/index.yaml"
GLOBAL_LOCK="$GLOBAL_DIR/global.lock"
GLOBAL_SIDECAR="$GLOBAL_INSTINCTS_DIR/.graduate-state.yaml"
GLOBAL_WARN_FILE="$GLOBAL_DIR/.graduation-warning"

# ── Counters ───────────────────────────────────────────────────────────────
P_propose=0
P_auto=0
P_auto_completed=0
G_propose=0
G_auto=0
G_auto_completed=0

# Resume-pre-pass tracker (any approve calls during resume scan)
RESUME_CALLS=0

# ── Helper: rebuild candidates after lock reacquire ───────────────────────
# Reads filtered candidates (pending instinct ids and archived single-instinct
# memory rejection ids) from a freshly read index. Used to drop newly-blocked
# candidates after the lock-release-during-agent window.

# read_pending_memory_instinct_ids <proposal_index_path> <proposals_dir> <src_field> <count_field>
# Outputs newline-separated instinct ids that are sources of pending memory
# proposals where ${count_field} == 1. <src_field> is e.g. "source_instincts"
# (project) or "source_global_instincts" (global).
read_pending_memory_instinct_ids() {
  local idx="$1" pdir="$2" src_field="$3" count_field="$4"
  [[ -f "$idx" ]] || return 0
  local count
  count=$(yq '.proposals | length' "$idx" 2>/dev/null || echo "0")
  local i pf pp ptype pcnt pid_inst
  for ((i=0; i<count; i++)); do
    pf=$(yq ".proposals[$i].file" "$idx" 2>/dev/null || echo "")
    pp="$pdir/$pf"
    [[ -f "$pp" ]] || continue
    ptype=$(yq '.type // ""' "$pp" 2>/dev/null || echo "")
    [[ "$ptype" == "memory" ]] || continue
    pcnt=$(yq ".${count_field} // 0" "$pp" 2>/dev/null || echo "0")
    [[ "$pcnt" == "1" ]] || continue
    pid_inst=$(yq ".${src_field}[0] // \"\"" "$pp" 2>/dev/null || echo "")
    [[ -n "$pid_inst" ]] && printf '%s\n' "$pid_inst"
  done
}

# read_pending_memory_proposal_for_instinct <proposal_index_path> <proposals_dir> <instinct_id> <src_field> <count_field>
# Outputs the proposal file basename if a pending memory proposal exists for the
# given instinct id (single-instinct memory). Empty otherwise.
read_pending_memory_proposal_for_instinct() {
  local idx="$1" pdir="$2" want="$3" src_field="$4" count_field="$5"
  [[ -f "$idx" ]] || return 0
  local count
  count=$(yq '.proposals | length' "$idx" 2>/dev/null || echo "0")
  local i pf pp ptype pcnt pid_inst
  for ((i=0; i<count; i++)); do
    pf=$(yq ".proposals[$i].file" "$idx" 2>/dev/null || echo "")
    pp="$pdir/$pf"
    [[ -f "$pp" ]] || continue
    ptype=$(yq '.type // ""' "$pp" 2>/dev/null || echo "")
    [[ "$ptype" == "memory" ]] || continue
    pcnt=$(yq ".${count_field} // 0" "$pp" 2>/dev/null || echo "0")
    [[ "$pcnt" == "1" ]] || continue
    pid_inst=$(yq ".${src_field}[0] // \"\"" "$pp" 2>/dev/null || echo "")
    if [[ "$pid_inst" == "$want" ]]; then
      printf '%s' "$pf"
      return 0
    fi
  done
}

# read_archived_memory_block_ids <archived_index_path> <src_field> <count_field>
# Outputs newline-separated instinct ids that are sources of single-instinct
# memory proposals with status in {rejected, permanently_rejected}.
# Excludes superseded_by_auto.
read_archived_memory_block_ids() {
  local idx="$1" src_field="$2" count_field="$3"
  [[ -f "$idx" ]] || return 0
  local count
  count=$(yq '.proposals | length' "$idx" 2>/dev/null || echo "0")
  local i ptype pstatus pcnt pid_inst
  for ((i=0; i<count; i++)); do
    ptype=$(yq ".proposals[$i].type // \"\"" "$idx" 2>/dev/null || echo "")
    [[ "$ptype" == "memory" ]] || continue
    pstatus=$(yq ".proposals[$i].status // \"\"" "$idx" 2>/dev/null || echo "")
    if [[ "$pstatus" != "rejected" && "$pstatus" != "permanently_rejected" ]]; then
      continue
    fi
    pcnt=$(yq ".proposals[$i].${count_field} // 0" "$idx" 2>/dev/null || echo "0")
    [[ "$pcnt" == "1" ]] || continue
    pid_inst=$(yq ".proposals[$i].${src_field}[0] // \"\"" "$idx" 2>/dev/null || echo "")
    [[ -n "$pid_inst" ]] && printf '%s\n' "$pid_inst"
  done
}

# read_skipped_buffer <sidecar_path>
# Outputs newline-separated "id<TAB>conf" pairs from sidecar.
read_skipped_buffer() {
  local sc="$1"
  [[ -f "$sc" ]] || return 0
  local count
  count=$(yq '.skipped | length' "$sc" 2>/dev/null || echo "0")
  local i sid sconf
  for ((i=0; i<count; i++)); do
    sid=$(yq ".skipped[$i].id // \"\"" "$sc" 2>/dev/null || echo "")
    sconf=$(yq ".skipped[$i].skipped_at_confidence // 0" "$sc" 2>/dev/null || echo "0")
    [[ -n "$sid" ]] && printf '%s\t%s\n' "$sid" "$sconf"
  done
}

# ── Resume-orphans pre-pass per scope ──────────────────────────────────────
# resume_orphans <scope=project|global>
# Runs index scan and (if it completes) directory scan, calling the appropriate
# approve script for each pending auto_approve_target proposal. Acquires the
# scope's lock non-blocking; on contention skips the entire pre-pass.
resume_orphans() {
  local scope="$1"
  local lock_file proposals_dir proposal_index approve_script project_arg
  if [[ "$scope" == "project" ]]; then
    lock_file="$LOCK_FILE"
    proposals_dir="$PROPOSALS_DIR"
    proposal_index="$PROPOSAL_INDEX"
    approve_script="$EVOLVE_DIR/scripts/approve-proposal.sh"
    project_arg="$PROJECT_ID"
  else
    lock_file="$GLOBAL_LOCK"
    proposals_dir="$GLOBAL_PROPOSALS_DIR"
    proposal_index="$GLOBAL_PROPOSAL_INDEX"
    approve_script="$EVOLVE_DIR/scripts/approve-global-proposal.sh"
    project_arg=""
  fi

  if ! acquire_lock "$lock_file"; then
    evolve_log "graduate.sh: $scope lock held, skipping $scope pre-pass"
    return 0
  fi
  trap "release_lock \"$lock_file\"" EXIT

  # ── Index scan ───────────────────────────────────────────────────────────
  local index_clean=1
  if [[ -f "$proposal_index" ]]; then
    local pcount
    pcount=$(yq '.proposals | length' "$proposal_index" 2>/dev/null || echo "0")
    local i prop_id prop_file prop_path prop_aat prop_aattempts content_file
    for ((i=0; i<pcount; i++)); do
      prop_id=$(yq ".proposals[$i].id // \"\"" "$proposal_index" 2>/dev/null || echo "")
      prop_file=$(yq ".proposals[$i].file // \"\"" "$proposal_index" 2>/dev/null || echo "")
      [[ -z "$prop_id" || -z "$prop_file" ]] && continue
      prop_path="$proposals_dir/$prop_file"
      [[ -f "$prop_path" ]] || continue

      prop_aat=$(yq '.auto_approve_target // false' "$prop_path" 2>/dev/null || echo "false")
      local prop_status
      prop_status=$(yq '.status // ""' "$prop_path" 2>/dev/null || echo "")
      [[ "$prop_aat" == "true" && "$prop_status" == "pending" ]] || continue

      prop_aattempts=$(yq '.auto_approve_attempts // 0' "$prop_path" 2>/dev/null || echo "0")
      if [[ "$prop_aattempts" -ge 3 ]]; then
        evolve_log "WARN graduate.sh: proposal $prop_id has reached max auto-approve attempts; skipping (manual /evolve required)"
        continue
      fi

      # Bump auto_approve_attempts atomically (lock held).
      local tmp_aa
      tmp_aa=$(mktemp)
      yq '.auto_approve_attempts = (.auto_approve_attempts // 0) + 1' "$prop_path" > "$tmp_aa"
      mv "$tmp_aa" "$prop_path"

      # Reconstruct CONTENT_FILE.
      content_file=$(mktemp)
      yq '.proposed_content // ""' "$prop_path" > "$content_file"

      # Release lock for approve call.
      release_lock "$lock_file"
      trap - EXIT

      RESUME_CALLS=$((RESUME_CALLS + 1))
      if [[ "$scope" == "project" ]]; then
        if ! "$approve_script" "$project_arg" "$prop_id" "" "$content_file" >/dev/null 2>&1; then
          evolve_log "INFO graduate.sh: resume-approve failed for $prop_id (will retry next run)"
        fi
      else
        if ! "$approve_script" "$prop_id" >/dev/null 2>&1; then
          evolve_log "INFO graduate.sh: resume-approve failed for $prop_id (will retry next run)"
        fi
      fi
      rm -f "$content_file"

      # Reacquire lock for next iteration.
      if ! acquire_lock "$lock_file"; then
        evolve_log "INFO graduate.sh: lost $scope lock during resume index scan; aborting pre-pass"
        index_clean=0
        break
      fi
      trap "release_lock \"$lock_file\"" EXIT
    done
  fi

  # ── Directory scan (only if index scan completed cleanly) ───────────────
  if [[ "$index_clean" == "1" && -d "$proposals_dir" ]]; then
    local f bn pf_aat pf_status pf_id pf_type pf_pc dir_clean
    dir_clean=1
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      [[ -f "$f" ]] || continue
      bn=$(basename "$f")

      # Skip if already in live index.
      if [[ -f "$proposal_index" ]]; then
        local in_idx
        in_idx=$(yq "[.proposals[] | select(.file == \"${bn}\")] | length" "$proposal_index" 2>/dev/null || echo "0")
        [[ "$in_idx" -gt 0 ]] && continue
      fi

      # Read fields; require structural validity.
      pf_aat=$(yq '.auto_approve_target // false' "$f" 2>/dev/null || echo "false")
      pf_status=$(yq '.status // ""' "$f" 2>/dev/null || echo "")
      pf_id=$(yq '.id // ""' "$f" 2>/dev/null || echo "")
      pf_type=$(yq '.type // ""' "$f" 2>/dev/null || echo "")
      pf_pc=$(yq '.proposed_content // ""' "$f" 2>/dev/null || echo "")

      [[ "$pf_aat" == "true" && "$pf_status" == "pending" ]] || continue

      if [[ -z "$pf_id" || -z "$pf_type" || -z "$pf_pc" ]]; then
        evolve_log "WARN graduate.sh: orphan $bn structurally invalid; skipping"
        continue
      fi

      # Repair-by-append to live index (atomic temp+mv).
      local pf_domain tmp_idx
      pf_domain=$(yq '.domain // "unknown"' "$f" 2>/dev/null || echo "unknown")
      tmp_idx=$(mktemp)
      yq ".proposals += [{
        \"id\": \"${pf_id}\",
        \"type\": \"${pf_type}\",
        \"domain\": \"${pf_domain}\",
        \"status\": \"pending\",
        \"file\": \"${bn}\"
      }]" "$proposal_index" > "$tmp_idx"
      mv "$tmp_idx" "$proposal_index"

      # Check attempt count and bump.
      local pf_aattempts
      pf_aattempts=$(yq '.auto_approve_attempts // 0' "$f" 2>/dev/null || echo "0")
      if [[ "$pf_aattempts" -ge 3 ]]; then
        evolve_log "WARN graduate.sh: orphan $pf_id has reached max auto-approve attempts; skipping"
        continue
      fi

      local tmp_aa
      tmp_aa=$(mktemp)
      yq '.auto_approve_attempts = (.auto_approve_attempts // 0) + 1' "$f" > "$tmp_aa"
      mv "$tmp_aa" "$f"

      # Reconstruct CONTENT_FILE.
      local content_file
      content_file=$(mktemp)
      yq '.proposed_content // ""' "$f" > "$content_file"

      # Release lock and call approve script.
      release_lock "$lock_file"
      trap - EXIT

      RESUME_CALLS=$((RESUME_CALLS + 1))
      if [[ "$scope" == "project" ]]; then
        if ! "$approve_script" "$project_arg" "$pf_id" "" "$content_file" >/dev/null 2>&1; then
          evolve_log "INFO graduate.sh: resume-approve (orphan dir scan) failed for $pf_id"
        fi
      else
        if ! "$approve_script" "$pf_id" >/dev/null 2>&1; then
          evolve_log "INFO graduate.sh: resume-approve (orphan dir scan) failed for $pf_id"
        fi
      fi
      rm -f "$content_file"

      # Reacquire lock.
      if ! acquire_lock "$lock_file"; then
        evolve_log "INFO graduate.sh: lost $scope lock during resume dir scan; aborting"
        dir_clean=0
        break
      fi
      trap "release_lock \"$lock_file\"" EXIT
    done < <(find "$proposals_dir" -maxdepth 1 -name '*.yaml' -type f 2>/dev/null)
  fi

  release_lock "$lock_file"
  trap - EXIT
}

# ── parse_agent_yaml <agent_output_var> -> sets globals: PARSE_NAME, PARSE_TITLE,
# PARSE_DESCRIPTION, PARSE_PROPOSED_CONTENT_PATH (a tempfile path), PARSE_OK.
# Caller is responsible for `rm -f "$PARSE_PROPOSED_CONTENT_PATH"`.
parse_agent_yaml() {
  PARSE_OK=0
  PARSE_NAME=""
  PARSE_TITLE=""
  PARSE_DESCRIPTION=""
  PARSE_PROPOSED_CONTENT_PATH=""
  local out="$1"
  local tmp
  tmp=$(mktemp)
  printf '%s\n' "$out" > "$tmp"

  local n t d
  n=$(yq '.name // ""' "$tmp" 2>/dev/null || echo "")
  t=$(yq '.title // ""' "$tmp" 2>/dev/null || echo "")
  d=$(yq '.description // ""' "$tmp" 2>/dev/null || echo "")

  if [[ -z "$n" || -z "$t" || -z "$d" ]]; then
    rm -f "$tmp"
    return 1
  fi

  if ! validate_id "$n"; then
    rm -f "$tmp"
    return 1
  fi
  # Defense-in-depth: enforce the agent prompt's 45-char cap (validate_id allows up to 80).
  if [[ "${#n}" -gt 45 ]]; then
    rm -f "$tmp"
    return 1
  fi
  # Forbidden patterns
  if [[ "$n" == global-* ]]; then
    rm -f "$tmp"
    return 1
  fi
  if [[ "$n" =~ -[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    rm -f "$tmp"
    return 1
  fi

  # Extract proposed_content.
  local pc_path
  pc_path=$(mktemp)
  yq '.proposed_content // ""' "$tmp" > "$pc_path"
  if [[ ! -s "$pc_path" ]]; then
    rm -f "$tmp" "$pc_path"
    return 1
  fi

  rm -f "$tmp"
  PARSE_NAME="$n"
  PARSE_TITLE="$t"
  PARSE_DESCRIPTION="$d"
  PARSE_PROPOSED_CONTENT_PATH="$pc_path"
  PARSE_OK=1
  return 0
}

# ── Main scope pass ────────────────────────────────────────────────────────
# scope_pass <scope> -- runs project or global pass.
# Exits via global-side-effects on counter increments.
scope_pass() {
  local scope="$1"
  local lock_file instincts_dir instincts_index proposals_dir proposal_index
  local proposal_archived_dir proposal_archived_index sidecar warn_file approve_script
  local project_arg
  local instinct_section_yq src_field count_field

  if [[ "$scope" == "project" ]]; then
    lock_file="$LOCK_FILE"
    instincts_dir="$INSTINCTS_DIR"
    instincts_index="$INSTINCTS_INDEX"
    proposals_dir="$PROPOSALS_DIR"
    proposal_index="$PROPOSAL_INDEX"
    proposal_archived_dir="$PROPOSAL_ARCHIVED_DIR"
    proposal_archived_index="$PROPOSAL_ARCHIVED_INDEX"
    sidecar="$SIDECAR"
    warn_file="$WARN_FILE"
    approve_script="$EVOLVE_DIR/scripts/approve-proposal.sh"
    project_arg="$PROJECT_ID"
    instinct_section_yq=".instincts"
    src_field="source_instincts"
    count_field="source_instinct_count"
  else
    lock_file="$GLOBAL_LOCK"
    instincts_dir="$GLOBAL_INSTINCTS_DIR"
    instincts_index="$GLOBAL_INSTINCTS_INDEX"
    proposals_dir="$GLOBAL_PROPOSALS_DIR"
    proposal_index="$GLOBAL_PROPOSAL_INDEX"
    proposal_archived_dir="$GLOBAL_PROPOSAL_ARCHIVED_DIR"
    proposal_archived_index="$GLOBAL_PROPOSAL_ARCHIVED_INDEX"
    sidecar="$GLOBAL_SIDECAR"
    warn_file="$GLOBAL_WARN_FILE"
    approve_script="$EVOLVE_DIR/scripts/approve-global-proposal.sh"
    project_arg=""
    instinct_section_yq=".instincts"
    src_field="source_global_instincts"
    count_field="source_global_instinct_count"
  fi

  # ── Acquire lock (non-blocking) ───────────────────────────────────────
  if ! acquire_lock "$lock_file"; then
    evolve_log "graduate.sh: $scope lock held, skipping $scope pass"
    return 0
  fi
  trap "release_lock \"$lock_file\"" EXIT

  # ── Read thresholds + max_per_run + agent_model ───────────────────────
  local propose_threshold auto_threshold max_per_run agent_model max_confidence
  if [[ "$scope" == "project" ]]; then
    propose_threshold=$(read_config '.instincts.propose_memory_threshold // 0.85' "$PROJECT_ID" 2>/dev/null || echo "0.85")
    propose_threshold=$(validate_numeric "$propose_threshold" "$_NUMERIC_NONNEG_FLOAT" "0.85")
    auto_threshold=$(read_config '.instincts.auto_memory_threshold // 0.95' "$PROJECT_ID" 2>/dev/null || echo "0.95")
    auto_threshold=$(validate_numeric "$auto_threshold" "$_NUMERIC_NONNEG_FLOAT" "0.95")
    max_confidence=$(read_config '.instincts.max_confidence // 1' "$PROJECT_ID" 2>/dev/null || echo "1")
    max_confidence=$(validate_numeric "$max_confidence" "$_NUMERIC_NONNEG_FLOAT" "1")
  else
    propose_threshold=$(read_config '.global_instincts.propose_memory_threshold // 0.85' 2>/dev/null || echo "0.85")
    propose_threshold=$(validate_numeric "$propose_threshold" "$_NUMERIC_NONNEG_FLOAT" "0.85")
    auto_threshold=$(read_config '.global_instincts.auto_memory_threshold // 0.95' 2>/dev/null || echo "0.95")
    auto_threshold=$(validate_numeric "$auto_threshold" "$_NUMERIC_NONNEG_FLOAT" "0.95")
    max_confidence=$(read_config '.global_instincts.max_confidence // 1' 2>/dev/null || echo "1")
    max_confidence=$(validate_numeric "$max_confidence" "$_NUMERIC_NONNEG_FLOAT" "1")
  fi
  max_per_run=$(read_config '.graduation.max_per_run_per_scope // 10' "$PROJECT_ID" 2>/dev/null || echo "10")
  max_per_run=$(validate_numeric "$max_per_run" "$_NUMERIC_NONNEG_INT" "10")
  agent_model=$(read_config '.graduation.agent_model // "claude-haiku-4-5-20251001"' "$PROJECT_ID" 2>/dev/null || echo "claude-haiku-4-5-20251001")

  # ── Threshold validation (write/clear warning file) ───────────────────
  local invalid=0
  if (( $(echo "$auto_threshold < $propose_threshold" | bc -l) )); then
    invalid=1
  elif (( $(echo "$auto_threshold > $max_confidence" | bc -l) )); then
    invalid=1
  elif (( $(echo "$propose_threshold > $max_confidence" | bc -l) )); then
    invalid=1
  fi
  if [[ "$invalid" == "1" ]]; then
    printf '[claude-evolve] graduation thresholds invalid in %s (auto=%s, propose=%s, max_confidence=%s); see evolve.log\n' \
      "$scope" "$auto_threshold" "$propose_threshold" "$max_confidence" > "$warn_file"
    evolve_log "WARN graduate.sh: $scope thresholds invalid (auto=$auto_threshold, propose=$propose_threshold, max=$max_confidence)"
    release_lock "$lock_file"
    trap - EXIT
    return 0
  else
    rm -f "$warn_file"
  fi

  # ── Build PENDING_INST_IDS (single-instinct memory pending) ───────────
  local pending_ids_str
  pending_ids_str=$(read_pending_memory_instinct_ids "$proposal_index" "$proposals_dir" "$src_field" "$count_field")

  # ── Build ARCHIVED_BLOCK_IDS (single-instinct memory rejected/perm rejected) ──
  local archived_block_ids_str
  archived_block_ids_str=$(read_archived_memory_block_ids "$proposal_archived_index" "$src_field" "$count_field")

  # ── Read sidecar skip-state ───────────────────────────────────────────
  local skipped_buf
  skipped_buf=$(read_skipped_buffer "$sidecar")

  # ── Build candidates list from instinct index ─────────────────────────
  local candidates_buf=""
  if [[ -f "$instincts_index" ]]; then
    local inst_total
    inst_total=$(yq "$instinct_section_yq | length" "$instincts_index" 2>/dev/null || echo "0")
    local i inst_id conf
    for ((i=0; i<inst_total; i++)); do
      inst_id=$(yq "${instinct_section_yq}[$i].id // \"\"" "$instincts_index" 2>/dev/null || echo "")
      conf=$(yq "${instinct_section_yq}[$i].confidence // 0" "$instincts_index" 2>/dev/null || echo "0")
      [[ -z "$inst_id" ]] && continue

      # Skip if confidence below propose threshold.
      if (( $(echo "$conf < $propose_threshold" | bc -l) )); then
        continue
      fi

      # Skip if in pending memory proposal (single-instinct), but ONLY if
      # the candidate is propose-tier. Auto-tier candidates preempt the pending
      # proposal (see "Auto-tier preempts pending propose" below).
      if [[ -n "$pending_ids_str" ]] && (( $(echo "$conf < $auto_threshold" | bc -l) )); then
        if echo "$pending_ids_str" | grep -qx "$inst_id"; then
          continue
        fi
      fi

      # Skip if in archived rejected memory single-instinct block.
      if [[ -n "$archived_block_ids_str" ]]; then
        if echo "$archived_block_ids_str" | grep -qx "$inst_id"; then
          continue
        fi
      fi

      # Skip if in sidecar with current confidence < skipped_at_confidence + 0.1.
      if [[ -n "$skipped_buf" ]]; then
        local sk_line sk_conf
        sk_line=$(printf '%s\n' "$skipped_buf" | awk -v want="$inst_id" -F'\t' '$1==want{print; exit}')
        if [[ -n "$sk_line" ]]; then
          sk_conf=$(printf '%s' "$sk_line" | awk -F'\t' '{print $2}')
          if (( $(echo "$conf < ($sk_conf + 0.1)" | bc -l) )); then
            continue
          fi
        fi
      fi

      candidates_buf+="${conf}"$'\t'"${inst_id}"$'\n'
    done
  fi

  # ── Sort by confidence desc, cap to max_per_run ───────────────────────
  local sorted
  sorted=$(printf '%s' "$candidates_buf" | sort -t$'\t' -k1 -rn | head -n "$max_per_run")

  # ── Build CANDS_SNAPSHOT array ────────────────────────────────────────
  local CANDS_SNAPSHOT=()
  if [[ -n "$sorted" ]]; then
    while IFS=$'\t' read -r conf inst_id; do
      [[ -z "$inst_id" ]] && continue
      local inst_yaml="$instincts_dir/${inst_id}.yaml"
      [[ -f "$inst_yaml" ]] || continue
      local domain
      domain=$(yq '.domain // "unknown"' "$inst_yaml" 2>/dev/null || echo "unknown")
      CANDS_SNAPSHOT+=("${conf}	${inst_id}	${inst_yaml}	${domain}")
    done <<< "$sorted"
  fi

  if [[ ${#CANDS_SNAPSHOT[@]} -eq 0 ]]; then
    evolve_log "graduate.sh: $scope pass -- no candidates"
    release_lock "$lock_file"
    trap - EXIT
    return 0
  fi

  # ── Release lock for agent calls ──────────────────────────────────────
  release_lock "$lock_file"
  trap - EXIT

  # ── For each candidate: invoke memory-writer agent ────────────────────
  # Buffers: SKIP_BUFFER (newline-sep "id<TAB>conf"), RESULTS_BUFFER (newline-sep
  # "tier<TAB>conf<TAB>inst_id<TAB>name<TAB>title<TAB>description<TAB>pc_path<TAB>domain")
  local SKIP_BUFFER=""
  local RESULTS_BUFFER=""
  local TEMP_PCS=()
  local cand
  for cand in ${CANDS_SNAPSHOT[@]+"${CANDS_SNAPSHOT[@]}"}; do
    local cconf cinst cyaml cdomain tier
    cconf=$(printf '%s' "$cand" | awk -F'\t' '{print $1}')
    cinst=$(printf '%s' "$cand" | awk -F'\t' '{print $2}')
    cyaml=$(printf '%s' "$cand" | awk -F'\t' '{print $3}')
    cdomain=$(printf '%s' "$cand" | awk -F'\t' '{print $4}')

    if (( $(echo "$cconf >= $auto_threshold" | bc -l) )); then
      tier="auto"
    else
      tier="propose"
    fi

    local agent_output
    agent_output=$(EVOLVE_AGENT_MODEL_OVERRIDE="$agent_model" \
      invoke_agent "$EVOLVE_DIR/agents/memory-writer.md" \
      < "$cyaml" 2>/dev/null) || {
        evolve_log "WARN graduate.sh: agent invocation failed for $cinst"
        continue
      }

    # Parse: trim and take first non-empty line for INSUFFICIENT_CONTEXT check.
    local first_line
    first_line=$(printf '%s\n' "$agent_output" | awk 'NF{print; exit}')
    # Trim
    first_line="${first_line#"${first_line%%[![:space:]]*}"}"
    first_line="${first_line%"${first_line##*[![:space:]]}"}"
    if [[ "$first_line" == "INSUFFICIENT_CONTEXT" ]]; then
      SKIP_BUFFER+="${cinst}"$'\t'"${cconf}"$'\n'
      evolve_log "INFO graduate.sh: instinct $cinst -> insufficient_context (skipped)"
      continue
    fi

    if ! parse_agent_yaml "$agent_output"; then
      evolve_log "WARN graduate.sh: agent parse/validation failed for $cinst; output follows"
      evolve_log "WARN graduate.sh: $(printf '%s' "$agent_output" | tr '\n' ' ')"
      [[ -n "${PARSE_PROPOSED_CONTENT_PATH:-}" ]] && rm -f "$PARSE_PROPOSED_CONTENT_PATH"
      continue
    fi

    TEMP_PCS+=("$PARSE_PROPOSED_CONTENT_PATH")
    RESULTS_BUFFER+="${tier}"$'\t'"${cconf}"$'\t'"${cinst}"$'\t'"${PARSE_NAME}"$'\t'"${PARSE_TITLE}"$'\t'"${PARSE_DESCRIPTION}"$'\t'"${PARSE_PROPOSED_CONTENT_PATH}"$'\t'"${cdomain}"$'\n'
  done

  # ── Re-acquire lock for proposal writes ───────────────────────────────
  if ! acquire_lock "$lock_file"; then
    evolve_log "INFO graduate.sh: lost $scope lock after agent calls; deferring proposal writes to next run"
    # Cleanup pc temp files.
    local pc
    for pc in ${TEMP_PCS[@]+"${TEMP_PCS[@]}"}; do
      rm -f "$pc"
    done
    return 0
  fi
  trap "release_lock \"$lock_file\"" EXIT

  # ── Re-validate filters: drop newly-blocked candidates ────────────────
  local fresh_pending fresh_archived
  fresh_pending=$(read_pending_memory_instinct_ids "$proposal_index" "$proposals_dir" "$src_field" "$count_field")
  fresh_archived=$(read_archived_memory_block_ids "$proposal_archived_index" "$src_field" "$count_field")

  # Walk RESULTS_BUFFER, filter into FILTERED_BUFFER.
  local FILTERED_BUFFER=""
  if [[ -n "$RESULTS_BUFFER" ]]; then
    while IFS=$'\t' read -r r_tier r_conf r_inst r_name r_title r_desc r_pc r_domain; do
      [[ -z "$r_inst" ]] && continue
      # Re-check: archived rejected single-instinct.
      if [[ -n "$fresh_archived" ]] && echo "$fresh_archived" | grep -qx "$r_inst"; then
        evolve_log "INFO graduate.sh: instinct $r_inst now blocked by fresh archived rejection or pending proposal; discarding agent result"
        rm -f "$r_pc"
        continue
      fi
      # Re-check: pending memory proposal -- skip propose tier; auto tier preempts.
      if [[ "$r_tier" == "propose" ]] && [[ -n "$fresh_pending" ]] && echo "$fresh_pending" | grep -qx "$r_inst"; then
        evolve_log "INFO graduate.sh: instinct $r_inst now blocked by fresh archived rejection or pending proposal; discarding agent result"
        rm -f "$r_pc"
        continue
      fi
      FILTERED_BUFFER+="${r_tier}"$'\t'"${r_conf}"$'\t'"${r_inst}"$'\t'"${r_name}"$'\t'"${r_title}"$'\t'"${r_desc}"$'\t'"${r_pc}"$'\t'"${r_domain}"$'\n'
    done <<< "$(printf '%s' "$RESULTS_BUFFER")"
  fi

  # ── Apply deferred skip-state (atomic temp+mv to sidecar, ONCE) ───────
  if [[ -n "$SKIP_BUFFER" ]]; then
    # Initialize sidecar if missing.
    if [[ ! -f "$sidecar" ]]; then
      printf 'version: 1\nskipped: []\n' > "$sidecar"
    fi
    local skip_now
    skip_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local sk_inst sk_conf tmp_sc
    while IFS=$'\t' read -r sk_inst sk_conf; do
      [[ -z "$sk_inst" ]] && continue
      tmp_sc=$(mktemp)
      yq ".skipped += [{
        \"id\": \"${sk_inst}\",
        \"skipped_at\": \"${skip_now}\",
        \"skipped_at_confidence\": ${sk_conf}
      }]" "$sidecar" > "$tmp_sc"
      mv "$tmp_sc" "$sidecar"
    done <<< "$(printf '%s' "$SKIP_BUFFER")"
  fi

  # ── For each successful candidate: write proposal, dispatch ──────────
  local now_iso date_str
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  date_str=$(date -u +%Y-%m-%d)

  local lock_lost=0
  if [[ -n "$FILTERED_BUFFER" ]]; then
    while IFS=$'\t' read -r f_tier f_conf f_inst f_name f_title f_desc f_pc f_domain; do
      [[ -z "$f_inst" ]] && continue

      # Auto-tier preempts pending propose
      if [[ "$f_tier" == "auto" ]]; then
        local pending_file
        pending_file=$(read_pending_memory_proposal_for_instinct "$proposal_index" "$proposals_dir" "$f_inst" "$src_field" "$count_field")
        if [[ -n "$pending_file" ]]; then
          if [[ "$scope" == "project" ]]; then
            archive_proposal "$proposals_dir/$pending_file" \
              "$proposal_archived_dir" "$proposal_archived_index" \
              "$proposal_index" "superseded_by_auto" || \
              evolve_log "WARN graduate.sh: archive_proposal (project) failed for $pending_file"
          else
            # Global memory archival: inline to write correct source_global_instincts schema.
            local pend_path pend_arch_path pend_id pend_type pend_domain
            pend_path="$proposals_dir/$pending_file"
            pend_arch_path="$proposal_archived_dir/$pending_file"
            local pend_resolved_at
            pend_resolved_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            if [[ -f "$pend_path" ]]; then
              local tmp_pend
              tmp_pend=$(mktemp)
              yq ".status = \"superseded_by_auto\" | .resolved_at = \"${pend_resolved_at}\"" \
                "$pend_path" > "$tmp_pend"
              mv "$tmp_pend" "$pend_arch_path"
              rm -f "$pend_path"
            elif [[ ! -f "$pend_arch_path" ]]; then
              evolve_log "WARN graduate.sh: global pending proposal $pending_file missing from both paths; skipping inline archival"
              continue
            fi
            # Read fields from archived copy.
            pend_id=$(yq '.id // ""' "$pend_arch_path" 2>/dev/null || echo "")
            [[ -z "$pend_id" ]] && pend_id="${pending_file%.yaml}"
            pend_type=$(yq '.type // ""' "$pend_arch_path" 2>/dev/null || echo "")
            pend_domain=$(yq '.domain // "unknown"' "$pend_arch_path" 2>/dev/null || echo "unknown")
            # Rewrite live index removing entry.
            if [[ -f "$proposal_index" ]]; then
              local tmp_pend_idx
              tmp_pend_idx=$(mktemp)
              yq ".proposals = [.proposals[] | select(.id != \"${pend_id}\")]" \
                "$proposal_index" > "$tmp_pend_idx"
              mv "$tmp_pend_idx" "$proposal_index"
            fi
            # Append to archived index with correct global schema (idempotent).
            local ALREADY_ARCH_PEND
            ALREADY_ARCH_PEND=$(yq "[.proposals[] | select(.id == \"${pend_id}\")] | length" \
              "$proposal_archived_index" 2>/dev/null || echo "0")
            if [[ "$ALREADY_ARCH_PEND" -gt 0 ]]; then
              evolve_log "INFO graduate.sh: global archived index already has entry for $pend_id; skipping"
            else
              local pend_sgi_count pend_sgi_yaml
              pend_sgi_count=$(yq '.source_global_instincts | length' "$pend_arch_path" 2>/dev/null || echo "0")
              pend_sgi_yaml=""
              local pend_i
              for ((pend_i=0; pend_i<pend_sgi_count; pend_i++)); do
                local pend_sgi
                pend_sgi=$(yq ".source_global_instincts[${pend_i}]" "$pend_arch_path" 2>/dev/null || echo "")
                pend_sgi_yaml+="\"${pend_sgi}\", "
              done
              pend_sgi_yaml="${pend_sgi_yaml%, }"
              local tmp_pend_arch
              tmp_pend_arch=$(mktemp)
              yq ".proposals += [{
                \"id\": \"${pend_id}\",
                \"type\": \"${pend_type}\",
                \"domain\": \"${pend_domain}\",
                \"status\": \"superseded_by_auto\",
                \"resolved_at\": \"${pend_resolved_at}\",
                \"source_global_instincts\": [${pend_sgi_yaml}],
                \"source_global_instinct_count\": ${pend_sgi_count},
                \"file\": \"${pending_file}\"
              }]" "$proposal_archived_index" > "$tmp_pend_arch"
              mv "$tmp_pend_arch" "$proposal_archived_index"
            fi
          fi
        fi
      fi

      # ── Generate proposal id ─────────────────────────────────────────
      local proposal_id
      if [[ "$scope" == "project" ]]; then
        proposal_id="proposal-${f_name}-${date_str}"
      else
        proposal_id="global-proposal-${f_name}-memory-${date_str}"
      fi
      if ! validate_id "$proposal_id"; then
        evolve_log "WARN graduate.sh: generated proposal id invalid: $proposal_id (skipping)"
        rm -f "$f_pc"
        continue
      fi

      # ── Title and description need YAML escaping ─────────────────────
      local title_esc desc_esc auto_target_str
      title_esc=$(yaml_escape_dq "$f_title")
      desc_esc=$(yaml_escape_dq "$f_desc")
      if [[ "$f_tier" == "auto" ]]; then
        auto_target_str="true"
      else
        auto_target_str="false"
      fi

      # ── Read proposed_content from file ──────────────────────────────
      local pc_str
      pc_str=$(cat "$f_pc")

      # ── Write proposal yaml ──────────────────────────────────────────
      local proposal_path="$proposals_dir/${proposal_id}.yaml"
      if [[ "$scope" == "project" ]]; then
        cat > "$proposal_path" <<YAML
version: 1
id: ${proposal_id}
type: memory
domain: ${f_domain}
created: "${now_iso}"
title: "${title_esc}"
description: "${desc_esc}"
proposed_content: |
$(echo "$pc_str" | sed 's/^/  /')
source_instincts:
  - ${f_inst}
source_instinct_count: 1
auto_approve_target: ${auto_target_str}
auto_approve_attempts: 0
status: pending
YAML
      else
        cat > "$proposal_path" <<YAML
version: 1
id: ${proposal_id}
type: memory
domain: ${f_domain}
created: "${now_iso}"
title: "${title_esc}"
description: "${desc_esc}"
name: ${f_name}
proposed_content: |
$(echo "$pc_str" | sed 's/^/  /')
source_global_instincts:
  - ${f_inst}
source_global_instinct_count: 1
auto_approve_target: ${auto_target_str}
auto_approve_attempts: 0
status: pending
YAML
      fi

      # ── Atomic-append to live proposal index ─────────────────────────
      local tmp_idx
      tmp_idx=$(mktemp)
      yq ".proposals += [{
        \"id\": \"${proposal_id}\",
        \"type\": \"memory\",
        \"domain\": \"${f_domain}\",
        \"status\": \"pending\",
        \"file\": \"${proposal_id}.yaml\"
      }]" "$proposal_index" > "$tmp_idx"
      mv "$tmp_idx" "$proposal_index"

      # ── Counters ─────────────────────────────────────────────────────
      if [[ "$scope" == "project" ]]; then
        if [[ "$f_tier" == "propose" ]]; then
          P_propose=$((P_propose + 1))
        else
          P_auto=$((P_auto + 1))
        fi
      else
        if [[ "$f_tier" == "propose" ]]; then
          G_propose=$((G_propose + 1))
        else
          G_auto=$((G_auto + 1))
        fi
      fi

      evolve_log "INFO graduate.sh: instinct $f_inst (conf=${f_conf}, scope=${scope:0:1}) -> ${f_tier}"

      # ── Auto-tier dispatch ───────────────────────────────────────────
      if [[ "$f_tier" == "auto" ]]; then
        # Bump auto_approve_attempts to 1 atomically (under lock).
        local tmp_aa
        tmp_aa=$(mktemp)
        yq '.auto_approve_attempts = 1' "$proposal_path" > "$tmp_aa"
        mv "$tmp_aa" "$proposal_path"

        # Release lock for approve call.
        release_lock "$lock_file"
        trap - EXIT

        local approve_ok=0
        if [[ "$scope" == "project" ]]; then
          if "$approve_script" "$project_arg" "$proposal_id" "" "$f_pc" >/dev/null 2>&1; then
            approve_ok=1
          fi
        else
          if "$approve_script" "$proposal_id" >/dev/null 2>&1; then
            approve_ok=1
          fi
        fi

        if [[ "$approve_ok" == "1" ]]; then
          if [[ "$scope" == "project" ]]; then
            P_auto_completed=$((P_auto_completed + 1))
          else
            G_auto_completed=$((G_auto_completed + 1))
          fi
        else
          evolve_log "WARN graduate.sh: auto-approve failed for $proposal_id (will retry next run)"
        fi

        # Reacquire lock.
        if ! acquire_lock "$lock_file"; then
          evolve_log "INFO graduate.sh: lost $scope lock during auto dispatch; deferring remaining candidates to next run"
          lock_lost=1
          rm -f "$f_pc"
          break
        fi
        trap "release_lock \"$lock_file\"" EXIT
      fi

      rm -f "$f_pc"
    done <<< "$(printf '%s' "$FILTERED_BUFFER")"
  fi

  # ── Cleanup any unmarked temp files (covers filter-out / parse-fail paths) ──
  # Note: f_pc is rm'd inside the loop; PARSE_PROPOSED_CONTENT_PATH is rm'd
  # explicitly on parse failure. TEMP_PCS may also include filtered-out paths.
  # We've already rm'd surviving paths during the result-write loop.

  if [[ "$lock_lost" == "0" ]]; then
    release_lock "$lock_file"
    trap - EXIT
  fi
}

# ── Run resume pre-pass for both scopes ────────────────────────────────────
resume_orphans "project"
if [[ -d "$GLOBAL_DIR" ]]; then
  resume_orphans "global"
fi

# ── Run main passes ────────────────────────────────────────────────────────
scope_pass "project"
if [[ -d "$GLOBAL_DIR" ]]; then
  scope_pass "global"
fi

# ── Final git push ─────────────────────────────────────────────────────────
if [[ "$P_propose" -ne 0 || "$P_auto" -ne 0 || "$P_auto_completed" -ne 0 || \
      "$G_propose" -ne 0 || "$G_auto" -ne 0 || "$G_auto_completed" -ne 0 || \
      "$RESUME_CALLS" -ne 0 ]]; then
  evolve_git_push "evolve(graduate): ${P_propose}p+${P_auto_completed}a/${P_auto}a project, ${G_propose}p+${G_auto_completed}a/${G_auto}a global"
fi

evolve_log "graduate.sh: done (project: ${P_propose}p+${P_auto_completed}a/${P_auto}a, global: ${G_propose}p+${G_auto_completed}a/${G_auto}a)"
exit 0
