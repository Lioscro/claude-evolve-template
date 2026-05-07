#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$HOME/.claude/evolve/scripts/lib.sh"

# Log errors to evolve.log without swallowing exit code -- admin scripts must surface failures.
trap 'evolve_log "ERROR ${BASH_SOURCE[0]##*/}:$LINENO (exit $?)"' ERR

# ── Args ─────────────────────────────────────────────────────────────────
# --force: bypass 1-hour frequency gate and echo summary to stdout (used
# by the /promote skill for on-demand runs).
FORCE=0
if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
fi

# emit: always log; also echo to stdout when --force, so user-invoked
# runs surface progress and skip reasons.
emit() {
  evolve_log "$@"
  if [[ "$FORCE" -eq 1 ]]; then
    echo "$@"
  fi
}

# ── Subprocess / enabled checks ──────────────────────────────────────────
evolve_is_subprocess && exit 0
if ! evolve_enabled; then
  emit "promote.sh: evolve disabled, exiting"
  exit 0
fi

# ── Check global dir exists ──────────────────────────────────────────────
if [[ ! -d "$GLOBAL_DIR" ]]; then
  emit "promote.sh: global dir does not exist, exiting"
  exit 0
fi

# ── Paths ────────────────────────────────────────────────────────────────
GLOBAL_INSTINCT_DIR="$GLOBAL_DIR/instincts"
GLOBAL_INSTINCT_INDEX="$GLOBAL_INSTINCT_DIR/index.yaml"
GLOBAL_INSTINCT_ARCHIVED_DIR="$GLOBAL_INSTINCT_DIR/archived"
GLOBAL_INSTINCT_ARCHIVED_INDEX="$GLOBAL_INSTINCT_ARCHIVED_DIR/index.yaml"
GLOBAL_PROPOSAL_DIR="$GLOBAL_DIR/proposals"
GLOBAL_PROPOSAL_INDEX="$GLOBAL_PROPOSAL_DIR/index.yaml"
GLOBAL_PROPOSAL_ARCHIVED_DIR="$GLOBAL_PROPOSAL_DIR/archived"
GLOBAL_PROPOSAL_ARCHIVED_INDEX="$GLOBAL_PROPOSAL_ARCHIVED_DIR/index.yaml"
GLOBAL_LOCK="$GLOBAL_DIR/global.lock"

# ── Read config ──────────────────────────────────────────────────────────
AUTO_PROMOTE_THRESHOLD=$(read_config '.global_instincts.auto_promote_threshold // 3' 2>/dev/null || echo "3")
AUTO_PROMOTE_THRESHOLD=$(validate_numeric "$AUTO_PROMOTE_THRESHOLD" "$_NUMERIC_NONNEG_INT" "3")
PROPOSE_PROMOTE_THRESHOLD=$(read_config '.global_instincts.propose_promote_threshold // 2' 2>/dev/null || echo "2")
PROPOSE_PROMOTE_THRESHOLD=$(validate_numeric "$PROPOSE_PROMOTE_THRESHOLD" "$_NUMERIC_NONNEG_INT" "2")
GLOBAL_INITIAL_CONFIDENCE=$(read_config '.global_instincts.initial_confidence // 0.5' 2>/dev/null || echo "0.5")
GLOBAL_INITIAL_CONFIDENCE=$(validate_numeric "$GLOBAL_INITIAL_CONFIDENCE" "$_NUMERIC_NONNEG_FLOAT" "0.5")
GLOBAL_DECAY_PER_RUN=$(read_config '.global_instincts.decay_per_run // 0.02' 2>/dev/null || echo "0.02")
GLOBAL_DECAY_PER_RUN=$(validate_numeric "$GLOBAL_DECAY_PER_RUN" "$_NUMERIC_NONNEG_FLOAT" "0.02")
GLOBAL_DECAY_FLOOR=$(read_config '.global_instincts.decay_floor // 0' 2>/dev/null || echo "0")
GLOBAL_DECAY_FLOOR=$(validate_numeric "$GLOBAL_DECAY_FLOOR" "$_NUMERIC_NONNEG_FLOAT" "0")
OVERLAP_THRESHOLD=$(read_config '.clustering.rejection_overlap_threshold // 0.7' 2>/dev/null || echo "0.7")
OVERLAP_THRESHOLD=$(validate_numeric "$OVERLAP_THRESHOLD" "$_NUMERIC_NONNEG_FLOAT" "0.7")
MIN_GROUPING_SIZE=$(read_config '.clustering.min_grouping_size // 2' 2>/dev/null || echo "2")
MIN_GROUPING_SIZE=$(validate_numeric "$MIN_GROUPING_SIZE" "$_NUMERIC_NONNEG_INT" "2")

# ── Acquire global lock ──────────────────────────────────────────────────
if ! acquire_lock "$GLOBAL_LOCK"; then
  emit "promote.sh: global lock held, exiting"
  exit 0
fi
trap 'release_lock "$GLOBAL_LOCK"' EXIT

# ── Frequency gate ───────────────────────────────────────────────────────
LAST_RUN=""
if [[ -f "$GLOBAL_INSTINCT_INDEX" ]]; then
  LAST_RUN=$(yq '.last_promote_run // ""' "$GLOBAL_INSTINCT_INDEX" 2>/dev/null || echo "")
fi

if [[ "$FORCE" -ne 1 && -n "$LAST_RUN" && "$LAST_RUN" != "null" && "$LAST_RUN" != "" ]]; then
  # Convert to epoch for comparison
  # `date -j -f` parses in local time; force UTC so the trailing 'Z' is honoured.
  LAST_EPOCH=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_RUN" "+%s" 2>/dev/null || echo "0")
  NOW_EPOCH=$(date -u "+%s")
  ELAPSED=$((NOW_EPOCH - LAST_EPOCH))
  if [[ "$ELAPSED" -lt 3600 ]]; then
    evolve_log "promote.sh: last run was ${ELAPSED}s ago (< 3600s), skipping"
    exit 0
  fi
fi

# ── Read all project instinct indexes ────────────────────────────────────
PROJECT_INSTINCTS_INPUT=""
PROJECT_COUNT=0

for project_index in "$EVOLVE_DIR"/projects/*/instincts/index.yaml; do
  [[ -f "$project_index" ]] || continue

  # Extract project ID from path
  project_dir=$(dirname "$(dirname "$project_index")")
  project_id=$(basename "$project_dir")

  inst_count=$(yq '.instincts | length' "$project_index" 2>/dev/null || echo "0")
  if [[ "$inst_count" -eq 0 ]]; then
    continue
  fi

  instincts_dir="$(dirname "$project_index")"

  # Build YAML for this project's instincts
  project_yaml=""
  for ((i=0; i<inst_count; i++)); do
    inst_file=$(yq ".instincts[$i].file" "$project_index" 2>/dev/null || echo "")
    inst_path="$instincts_dir/$inst_file"
    if [[ -f "$inst_path" ]]; then
      project_yaml+="$(cat "$inst_path")"
      project_yaml+=$'\n---\n'
    fi
  done

  if [[ -n "$project_yaml" ]]; then
    PROJECT_INSTINCTS_INPUT+="### Project: $project_id"$'\n'
    PROJECT_INSTINCTS_INPUT+="$project_yaml"$'\n'
    PROJECT_COUNT=$((PROJECT_COUNT + 1))
  fi
done

if [[ "$PROJECT_COUNT" -lt 2 ]]; then
  emit "promote.sh: only $PROJECT_COUNT project(s) with instincts (need 2+), exiting"
  exit 0
fi

# ── Read existing global instincts ───────────────────────────────────────
GLOBAL_INSTINCTS_YAML=""
GLOBAL_INSTINCT_COUNT=0
if [[ -f "$GLOBAL_INSTINCT_INDEX" ]]; then
  GLOBAL_INSTINCT_COUNT=$(yq '.instincts | length' "$GLOBAL_INSTINCT_INDEX" 2>/dev/null || echo "0")
  for ((i=0; i<GLOBAL_INSTINCT_COUNT; i++)); do
    gfile=$(yq ".instincts[$i].file" "$GLOBAL_INSTINCT_INDEX" 2>/dev/null || echo "")
    gpath="$GLOBAL_INSTINCT_DIR/$gfile"
    if [[ -f "$gpath" ]]; then
      GLOBAL_INSTINCTS_YAML+="$(cat "$gpath")"
      GLOBAL_INSTINCTS_YAML+=$'\n---\n'
    fi
  done
fi

# ── Read archived global proposals (for overlap/duplicate prevention) ────
ARCHIVED_CONTEXT=""
ARCH_STATUSES=()
ARCH_SRC_IDS=()
ARCH_SRC_COUNTS=()

if [[ -f "$GLOBAL_PROPOSAL_ARCHIVED_INDEX" ]]; then
  ARCHIVED_COUNT=$(yq '.proposals | length' "$GLOBAL_PROPOSAL_ARCHIVED_INDEX" 2>/dev/null || echo "0")
  for ((i=0; i<ARCHIVED_COUNT; i++)); do
    status=$(yq ".proposals[$i].status" "$GLOBAL_PROPOSAL_ARCHIVED_INDEX")
    if [[ "$status" != "rejected" && "$status" != "permanently_rejected" && "$status" != "approved" ]]; then
      continue
    fi

    arch_id=$(yq ".proposals[$i].id" "$GLOBAL_PROPOSAL_ARCHIVED_INDEX")

    # Read source_project_instincts for overlap checking
    src_ids=""
    arch_file=$(yq ".proposals[$i].file // \"\"" "$GLOBAL_PROPOSAL_ARCHIVED_INDEX" 2>/dev/null || echo "")
    arch_path="$GLOBAL_PROPOSAL_ARCHIVED_DIR/$arch_file"
    if [[ -f "$arch_path" ]]; then
      spi_count=$(yq '.source_project_instincts | length' "$arch_path" 2>/dev/null || echo "0")
      for ((j=0; j<spi_count; j++)); do
        sp=$(yq ".source_project_instincts[$j].project" "$arch_path" 2>/dev/null || echo "")
        si=$(yq ".source_project_instincts[$j].instinct" "$arch_path" 2>/dev/null || echo "")
        src_ids+="${sp}/${si}"$'\n'
      done
    fi

    if [[ "$status" == "rejected" || "$status" == "permanently_rejected" ]]; then
      ARCH_STATUSES+=("$status")
      ARCH_SRC_IDS+=("$src_ids")
      src_count=$(yq ".proposals[$i].source_project_count // 0" "$GLOBAL_PROPOSAL_ARCHIVED_INDEX" 2>/dev/null || echo "0")
      ARCH_SRC_COUNTS+=("$src_count")

      ARCHIVED_CONTEXT+="- id: $arch_id"$'\n'
      ARCHIVED_CONTEXT+="  status: $status"$'\n'
      ARCHIVED_CONTEXT+="  source_project_instincts:"$'\n'
      ARCHIVED_CONTEXT+="$src_ids"
    fi
  done
fi

# ── Build agent input ────────────────────────────────────────────────────
AGENT_INPUT=""
AGENT_INPUT+="## Project Instincts"$'\n\n'
AGENT_INPUT+="$PROJECT_INSTINCTS_INPUT"
AGENT_INPUT+=$'\n'
AGENT_INPUT+="## Existing Global Instincts"$'\n\n'
if [[ -n "$GLOBAL_INSTINCTS_YAML" ]]; then
  AGENT_INPUT+="$GLOBAL_INSTINCTS_YAML"
else
  AGENT_INPUT+="(none)"$'\n'
fi
AGENT_INPUT+=$'\n'
AGENT_INPUT+="## Archived Global Proposals"$'\n\n'
if [[ -n "$ARCHIVED_CONTEXT" ]]; then
  AGENT_INPUT+="$ARCHIVED_CONTEXT"
else
  AGENT_INPUT+="(none)"$'\n'
fi

# ── Release global lock before agent invocation ──────────────────────────
release_lock "$GLOBAL_LOCK"
trap - EXIT

# ── Invoke promoter agent ────────────────────────────────────────────────
AGENT_OUTPUT=$(echo "$AGENT_INPUT" | invoke_agent "$EVOLVE_DIR/agents/promoter.md" 2>/dev/null) || {
  evolve_log "promote.sh: agent invocation failed"
  exit 0
}

# ── Check for NONE ───────────────────────────────────────────────────────
TRIMMED_OUTPUT=$(echo "$AGENT_OUTPUT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
if [[ "$TRIMMED_OUTPUT" == "NONE" ]]; then
  evolve_log "promote.sh: agent returned NONE"
  # Still need to do decay -- re-acquire lock below
fi

# ── Re-acquire global lock after agent returns ───────────────────────────
if ! acquire_lock "$GLOBAL_LOCK"; then
  evolve_log "promote.sh: could not re-acquire global lock after agent, exiting"
  exit 0
fi
trap 'release_lock "$GLOBAL_LOCK"' EXIT

# ── Jaccard similarity function ──────────────────────────────────────────
jaccard_similarity() {
  local set_a="$1"
  local set_b="$2"

  local union_count intersection_count
  union_count=$(printf '%s\n%s\n' "$set_a" "$set_b" | sort -u | grep -c . || echo "0")
  intersection_count=$(comm -12 <(echo "$set_a" | sort -u) <(echo "$set_b" | sort -u) | grep -c . || echo "0")

  if [[ "$union_count" -eq 0 ]]; then
    echo "0"
    return
  fi

  echo "scale=4; $intersection_count / $union_count" | bc -l
}

# ── Parse agent output ───────────────────────────────────────────────────
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DATE_STR=$(date -u +%Y-%m-%d)
PROMOTIONS=0
PROPOSALS_CREATED=0

process_promotion_document() {
  local doc="$1"
  [[ -z "$doc" ]] && return

  # Strip markdown code fences if present
  doc=$(echo "$doc" | sed '/^```yaml$/d; /^```$/d')

  # Parse fields from YAML using a temp file
  local tmp_doc
  tmp_doc=$(mktemp)
  echo "$doc" > "$tmp_doc"

  local inst_id trigger action domain
  inst_id=$(yq '.id // ""' "$tmp_doc" 2>/dev/null || echo "")
  trigger=$(yq '.trigger // ""' "$tmp_doc" 2>/dev/null || echo "")
  action=$(yq '.action // ""' "$tmp_doc" 2>/dev/null || echo "")
  domain=$(yq '.domain // "unknown"' "$tmp_doc" 2>/dev/null || echo "unknown")

  # Read source_project_instincts
  local spi_count
  spi_count=$(yq '.source_project_instincts | length' "$tmp_doc" 2>/dev/null || echo "0")

  if [[ -z "$inst_id" || "$spi_count" -eq 0 ]]; then
    evolve_log "promote.sh: skipping document with missing fields (id=$inst_id, spi_count=$spi_count)"
    rm -f "$tmp_doc"
    return
  fi

  # Validate agent-emitted identifiers BEFORE consumption (R5).
  if ! validate_id "$inst_id"; then
    evolve_log "WARN promote.sh: skipping document with invalid id='$inst_id'"
    rm -f "$tmp_doc"
    return
  fi
  if ! validate_id "$domain"; then
    evolve_log "WARN promote.sh: skipping document id='$inst_id' -- invalid domain='$domain'"
    rm -f "$tmp_doc"
    return
  fi

  # Count distinct source projects
  local projects=""
  local spi_yaml=""
  for ((si=0; si<spi_count; si++)); do
    local proj inst
    proj=$(yq ".source_project_instincts[$si].project" "$tmp_doc" 2>/dev/null || echo "")
    inst=$(yq ".source_project_instincts[$si].instinct" "$tmp_doc" 2>/dev/null || echo "")
    if ! validate_id "$proj" || ! validate_id "$inst"; then
      evolve_log "WARN promote.sh: skipping document id='$inst_id' -- invalid SPI[$si] project='$proj' instinct='$inst'"
      rm -f "$tmp_doc"
      return
    fi
    projects+="$proj"$'\n'
    spi_yaml+="  - project: $proj"$'\n'
    spi_yaml+="    instinct: $inst"$'\n'
  done
  local distinct_projects
  distinct_projects=$(echo "$projects" | sort -u | grep -c . || echo "0")

  # Build source IDs for overlap check (project/instinct format)
  local new_src_ids=""
  for ((si=0; si<spi_count; si++)); do
    local proj inst
    proj=$(yq ".source_project_instincts[$si].project" "$tmp_doc" 2>/dev/null || echo "")
    inst=$(yq ".source_project_instincts[$si].instinct" "$tmp_doc" 2>/dev/null || echo "")
    new_src_ids+="${proj}/${inst}"$'\n'
  done

  rm -f "$tmp_doc"

  # ── Overlap checks against archived global proposals ───────────────────
  local skip=0
  local arch_total=${#ARCH_STATUSES[@]}
  if [[ "$arch_total" -gt 0 ]]; then
    for ((ai=0; ai<arch_total; ai++)); do
      local arch_status="${ARCH_STATUSES[$ai]}"
      local arch_src="${ARCH_SRC_IDS[$ai]}"
      local arch_count="${ARCH_SRC_COUNTS[$ai]}"

      local jaccard
      jaccard=$(jaccard_similarity "$new_src_ids" "$arch_src")

      if (( $(echo "$jaccard > $OVERLAP_THRESHOLD" | bc -l) )); then
        if [[ "$arch_status" == "permanently_rejected" ]]; then
          evolve_log "promote.sh: skipping $inst_id -- overlaps with permanently rejected proposal (jaccard=$jaccard)"
          skip=1
          break
        elif [[ "$arch_status" == "rejected" ]]; then
          if [[ "$distinct_projects" -le "$arch_count" ]]; then
            evolve_log "promote.sh: skipping $inst_id -- overlaps with rejected proposal and count not exceeded ($distinct_projects <= $arch_count, jaccard=$jaccard)"
            skip=1
            break
          fi
        fi
      fi
    done
  fi

  if [[ "$skip" -eq 1 ]]; then
    return
  fi

  # ── Auto-promote or create proposal ────────────────────────────────────
  # Trigger and action are agent-emitted; escape for YAML.
  local trigger_esc action_esc
  trigger_esc=$(yaml_escape_dq "$trigger")
  action_esc=$(yaml_escape_dq "$action")

  if [[ "$distinct_projects" -ge "$AUTO_PROMOTE_THRESHOLD" ]]; then
    # Auto-promote: write instinct data to temp file, call promote-instinct.sh
    local tmp_instinct
    tmp_instinct=$(mktemp)
    cat > "$tmp_instinct" <<ENDYAML
id: ${inst_id}
trigger: "${trigger_esc}"
action: "${action_esc}"
domain: ${domain}
source_project_instincts:
${spi_yaml}
ENDYAML

    evolve_log "promote.sh: auto-promoting $inst_id ($distinct_projects projects)"

    # Release global lock before calling promote-instinct.sh
    release_lock "$GLOBAL_LOCK"
    trap - EXIT

    "$EVOLVE_DIR/scripts/promote-instinct.sh" "$tmp_instinct" 2>/dev/null || {
      evolve_log "promote.sh: promote-instinct.sh failed for $inst_id"
    }
    rm -f "$tmp_instinct"

    # Re-acquire global lock
    if ! acquire_lock "$GLOBAL_LOCK"; then
      evolve_log "promote.sh: could not re-acquire global lock after promotion"
      exit 0
    fi
    trap 'release_lock "$GLOBAL_LOCK"' EXIT

    PROMOTIONS=$((PROMOTIONS + 1))

  elif [[ "$distinct_projects" -ge "$PROPOSE_PROMOTE_THRESHOLD" ]]; then
    # Create promotion proposal
    local proposal_id="global-proposal-${inst_id}-${DATE_STR}"
    local proposal_file="${inst_id}-promotion.yaml"

    # Build source_projects list
    local src_projects_yaml=""
    local seen_projects=""
    for ((si=0; si<spi_count; si++)); do
      local proj
      # Re-parse from spi_yaml lines
      proj=$(echo "$spi_yaml" | sed -n "s/^  - project: //p" | sed -n "$((si + 1))p")
      if ! echo "$seen_projects" | grep -qx "$proj"; then
        src_projects_yaml+="  - $proj"$'\n'
        seen_projects+="$proj"$'\n'
      fi
    done

    cat > "$GLOBAL_PROPOSAL_DIR/$proposal_file" <<ENDYAML
version: 1
id: ${proposal_id}
type: promotion
domain: ${domain}
created: "${NOW}"
title: "Promote cross-project instinct: ${inst_id}"
description: "Instinct '${inst_id}' detected across ${distinct_projects} projects"
source_projects:
${src_projects_yaml}source_project_instincts:
${spi_yaml}source_project_count: ${distinct_projects}
proposed_trigger: "${trigger_esc}"
proposed_action: "${action_esc}"
status: pending
ENDYAML

    # Add to global proposal index (atomic write)
    local tmp_index
    tmp_index=$(mktemp)
    yq ".proposals += [{
      \"id\": \"${proposal_id}\",
      \"type\": \"promotion\",
      \"domain\": \"${domain}\",
      \"status\": \"pending\",
      \"file\": \"${proposal_file}\"
    }]" "$GLOBAL_PROPOSAL_INDEX" > "$tmp_index"
    mv "$tmp_index" "$GLOBAL_PROPOSAL_INDEX"

    evolve_log "promote.sh: created promotion proposal $proposal_id"
    PROPOSALS_CREATED=$((PROPOSALS_CREATED + 1))
  fi
}

# ── Process agent output (split on --- lines) ────────────────────────────
if [[ "$TRIMMED_OUTPUT" != "NONE" ]]; then
  CURRENT_DOC=""
  while IFS= read -r line; do
    if [[ "$line" == "---" ]]; then
      if [[ -n "$CURRENT_DOC" ]]; then
        process_promotion_document "$CURRENT_DOC"
      fi
      CURRENT_DOC=""
    else
      CURRENT_DOC+="$line"$'\n'
    fi
  done <<< "$AGENT_OUTPUT"

  # Process the last document
  if [[ -n "$CURRENT_DOC" ]]; then
    process_promotion_document "$CURRENT_DOC"
  fi
fi

# ── Apply global instinct decay ──────────────────────────────────────────
# For each global instinct not reinforced since last promote run, reduce confidence.
# Archive (not delete) if below decay_floor.
DECAYED_COUNT=0
ARCHIVED_COUNT=0

if [[ -f "$GLOBAL_INSTINCT_INDEX" ]]; then
  gi_count=$(yq '.instincts | length' "$GLOBAL_INSTINCT_INDEX" 2>/dev/null || echo "0")

  # Iterate in reverse so index deletions don't shift
  for ((i=gi_count-1; i>=0; i--)); do
    gi_id=$(yq ".instincts[$i].id" "$GLOBAL_INSTINCT_INDEX")
    gi_file=$(yq ".instincts[$i].file" "$GLOBAL_INSTINCT_INDEX")
    gi_path="$GLOBAL_INSTINCT_DIR/$gi_file"

    if [[ ! -f "$gi_path" ]]; then
      continue
    fi

    # Check last_reinforced vs last_promote_run
    last_reinforced=$(yq '.last_reinforced // ""' "$gi_path" 2>/dev/null || echo "")
    if [[ -n "$LAST_RUN" && "$LAST_RUN" != "null" && "$LAST_RUN" != "" && -n "$last_reinforced" ]]; then
      lr_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_reinforced" "+%s" 2>/dev/null || echo "0")
      lp_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_RUN" "+%s" 2>/dev/null || echo "0")

      if [[ "$lr_epoch" -gt "$lp_epoch" ]]; then
        # Reinforced since last run -- skip decay
        continue
      fi
    fi

    # Apply decay
    current_conf=$(yq '.confidence // 0' "$gi_path")
    new_conf=$(bc_calc "$current_conf - $GLOBAL_DECAY_PER_RUN")

    if (( $(echo "$new_conf < $GLOBAL_DECAY_FLOOR" | bc -l) )); then
      # Archive global instinct (not delete -- preserve provenance)
      ARCHIVED_COUNT=$((ARCHIVED_COUNT + 1))
      evolve_log "promote.sh: decayed global instinct $gi_id below floor ($new_conf < $GLOBAL_DECAY_FLOOR), archiving"

      gi_domain=$(yq '.domain // "unknown"' "$gi_path" 2>/dev/null || echo "unknown")

      # Add archival metadata
      tmp_gi=$(mktemp)
      yq "
        .confidence = ${new_conf} |
        .archived_reason = \"decayed_below_floor\" |
        .archived_at = \"${NOW}\"
      " "$gi_path" > "$tmp_gi"
      mv "$tmp_gi" "$GLOBAL_INSTINCT_ARCHIVED_DIR/${gi_id}.yaml"
      rm -f "$gi_path"

      # Remove from global instinct index
      tmp_idx=$(mktemp)
      yq "del(.instincts[$i])" "$GLOBAL_INSTINCT_INDEX" > "$tmp_idx"
      mv "$tmp_idx" "$GLOBAL_INSTINCT_INDEX"

      # Add to archived index
      tmp_arch=$(mktemp)
      yq ".instincts += [{
        \"id\": \"${gi_id}\",
        \"domain\": \"${gi_domain}\",
        \"archived_reason\": \"decayed_below_floor\",
        \"archived_at\": \"${NOW}\",
        \"file\": \"${gi_id}.yaml\"
      }]" "$GLOBAL_INSTINCT_ARCHIVED_INDEX" > "$tmp_arch"
      mv "$tmp_arch" "$GLOBAL_INSTINCT_ARCHIVED_INDEX"
    else
      # Update confidence
      DECAYED_COUNT=$((DECAYED_COUNT + 1))
      tmp_gi=$(mktemp)
      yq ".confidence = ${new_conf}" "$gi_path" > "$tmp_gi"
      mv "$tmp_gi" "$gi_path"

      tmp_idx=$(mktemp)
      yq "(.instincts[] | select(.id == \"${gi_id}\")).confidence = ${new_conf}" "$GLOBAL_INSTINCT_INDEX" > "$tmp_idx"
      mv "$tmp_idx" "$GLOBAL_INSTINCT_INDEX"
    fi
  done
fi

# ── Update last_promote_run ──────────────────────────────────────────────
tmp_idx=$(mktemp)
yq ".last_promote_run = \"${NOW}\"" "$GLOBAL_INSTINCT_INDEX" > "$tmp_idx"
mv "$tmp_idx" "$GLOBAL_INSTINCT_INDEX"

# ── Release lock ─────────────────────────────────────────────────────────
release_lock "$GLOBAL_LOCK"
trap - EXIT

emit "promote.sh: done ($PROMOTIONS promoted, $PROPOSALS_CREATED proposed, $DECAYED_COUNT decayed, $ARCHIVED_COUNT archived)"
exit 0
