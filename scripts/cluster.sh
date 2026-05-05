#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$HOME/.claude/evolve/scripts/lib.sh"

# Trap errors -- log and exit 0 (never block Claude)
trap 'evolve_trap $LINENO $?' ERR

# ── Arguments ──────────────────────────────────────────────────────────────
PROJECT_ID="${1:?cluster.sh requires PROJECT_ID as \$1}"

# ── Paths ──────────────────────────────────────────────────────────────────
PROJECT_DIR="$EVOLVE_DIR/projects/$PROJECT_ID"
INSTINCTS_DIR="$PROJECT_DIR/instincts"
INSTINCT_INDEX="$INSTINCTS_DIR/index.yaml"
PROPOSALS_DIR="$PROJECT_DIR/proposals"
PROPOSAL_INDEX="$PROPOSALS_DIR/index.yaml"
ARCHIVED_PROPOSAL_INDEX="$PROPOSALS_DIR/archived/index.yaml"
LOCK_FILE="$PROJECT_DIR/evolve.lock"

# ── Acquire lock (best-effort: silently exit 0 on contention) ─────────────
# observe.sh deliberately releases the lock before invoking cluster.sh, so
# acquiring here does not deadlock with the caller.
if ! acquire_lock "$LOCK_FILE"; then
  evolve_log "cluster.sh: lock held, exiting"
  exit 0
fi
trap 'release_lock "$LOCK_FILE"' EXIT

# ── Read config ────────────────────────────────────────────────────────────
MIN_CONFIDENCE=$(read_config '.clustering.min_confidence_for_clustering // 0.4' "$PROJECT_ID" 2>/dev/null || echo "0.4")
MIN_CONFIDENCE=$(validate_numeric "$MIN_CONFIDENCE" "$_NUMERIC_NONNEG_FLOAT" "0.4")
DOMAIN_THRESHOLD=$(read_config '.clustering.domain_threshold // 5' "$PROJECT_ID" 2>/dev/null || echo "5")
DOMAIN_THRESHOLD=$(validate_numeric "$DOMAIN_THRESHOLD" "$_NUMERIC_NONNEG_INT" "5")
OVERLAP_THRESHOLD=$(read_config '.clustering.rejection_overlap_threshold // 0.7' "$PROJECT_ID" 2>/dev/null || echo "0.7")
OVERLAP_THRESHOLD=$(validate_numeric "$OVERLAP_THRESHOLD" "$_NUMERIC_NONNEG_FLOAT" "0.7")
MIN_GROUPING_SIZE=$(read_config '.clustering.min_grouping_size // 2' "$PROJECT_ID" 2>/dev/null || echo "2")
MIN_GROUPING_SIZE=$(validate_numeric "$MIN_GROUPING_SIZE" "$_NUMERIC_NONNEG_INT" "2")

# ── Check instinct index ──────────────────────────────────────────────────
if [[ ! -f "$INSTINCT_INDEX" ]]; then
  evolve_log "cluster.sh: no instinct index, exiting"
  exit 0
fi

# ── Filter eligible instincts (confidence >= min_confidence) ──────────────
ELIGIBLE_IDS=()
ELIGIBLE_COUNT=0
TOTAL_COUNT=$(yq '.instincts | length' "$INSTINCT_INDEX" 2>/dev/null || echo "0")

for ((i=0; i<TOTAL_COUNT; i++)); do
  conf=$(yq ".instincts[$i].confidence" "$INSTINCT_INDEX")
  # Compare: conf >= MIN_CONFIDENCE
  if (( $(echo "$conf >= $MIN_CONFIDENCE" | bc -l) )); then
    inst_id=$(yq ".instincts[$i].id" "$INSTINCT_INDEX")
    ELIGIBLE_IDS+=("$inst_id")
    ELIGIBLE_COUNT=$((ELIGIBLE_COUNT + 1))
  fi
done

# ── Check domain_threshold ────────────────────────────────────────────────
if [[ "$ELIGIBLE_COUNT" -lt "$DOMAIN_THRESHOLD" ]]; then
  evolve_log "cluster.sh: only $ELIGIBLE_COUNT eligible instincts (need $DOMAIN_THRESHOLD), exiting"
  exit 0
fi

evolve_log "cluster.sh: $ELIGIBLE_COUNT eligible instincts"

# ── Read pending proposals and exclude their instinct IDs ─────────────────
PENDING_INSTINCT_IDS=""
if [[ -f "$PROPOSAL_INDEX" ]]; then
  PENDING_COUNT=$(yq '.proposals | length' "$PROPOSAL_INDEX" 2>/dev/null || echo "0")
  for ((i=0; i<PENDING_COUNT; i++)); do
    prop_file=$(yq ".proposals[$i].file" "$PROPOSAL_INDEX")
    prop_path="$PROPOSALS_DIR/$prop_file"
    if [[ -f "$prop_path" ]]; then
      src_count=$(yq '.source_instincts | length' "$prop_path" 2>/dev/null || echo "0")
      for ((j=0; j<src_count; j++)); do
        src_id=$(yq ".source_instincts[$j]" "$prop_path")
        PENDING_INSTINCT_IDS+="$src_id"$'\n'
      done
    fi
  done
fi

# Remove instincts already in pending proposals from eligible set
FILTERED_IDS=()
for eid in "${ELIGIBLE_IDS[@]}"; do
  if ! echo "$PENDING_INSTINCT_IDS" | grep -qx "$eid"; then
    FILTERED_IDS+=("$eid")
  fi
done

if [[ ${#FILTERED_IDS[@]} -lt "$DOMAIN_THRESHOLD" ]]; then
  evolve_log "cluster.sh: only ${#FILTERED_IDS[@]} eligible after pending exclusion (need $DOMAIN_THRESHOLD), exiting"
  exit 0
fi

# ── Build rejection context from archived proposals ───────────────────────
REJECTION_CONTEXT=""
if [[ -f "$ARCHIVED_PROPOSAL_INDEX" ]]; then
  ARCHIVED_COUNT=$(yq '.proposals | length' "$ARCHIVED_PROPOSAL_INDEX" 2>/dev/null || echo "0")
  for ((i=0; i<ARCHIVED_COUNT; i++)); do
    status=$(yq ".proposals[$i].status" "$ARCHIVED_PROPOSAL_INDEX")
    if [[ "$status" == "rejected" || "$status" == "permanently_rejected" ]]; then
      arch_id=$(yq ".proposals[$i].id" "$ARCHIVED_PROPOSAL_INDEX")
      src_count=$(yq ".proposals[$i].source_instincts | length" "$ARCHIVED_PROPOSAL_INDEX" 2>/dev/null || echo "0")
      src_ids=""
      for ((j=0; j<src_count; j++)); do
        sid=$(yq ".proposals[$i].source_instincts[$j]" "$ARCHIVED_PROPOSAL_INDEX")
        src_ids+="  - $sid"$'\n'
      done
      REJECTION_CONTEXT+="- id: $arch_id"$'\n'
      REJECTION_CONTEXT+="  status: $status"$'\n'
      REJECTION_CONTEXT+="  source_instincts:"$'\n'
      REJECTION_CONTEXT+="$src_ids"
    fi
  done
fi

# ── Build eligible instincts YAML for agent input ─────────────────────────
ELIGIBLE_YAML=""
for eid in "${FILTERED_IDS[@]}"; do
  inst_file="$INSTINCTS_DIR/${eid}.yaml"
  if [[ -f "$inst_file" ]]; then
    ELIGIBLE_YAML+="$(cat "$inst_file")"
    ELIGIBLE_YAML+=$'\n---\n'
  fi
done

# ── Build agent input ─────────────────────────────────────────────────────
AGENT_INPUT=""
AGENT_INPUT+="## Eligible Instincts"$'\n\n'
AGENT_INPUT+="$ELIGIBLE_YAML"
AGENT_INPUT+=$'\n'
AGENT_INPUT+="## Previously Rejected Groupings"$'\n\n'
if [[ -n "$REJECTION_CONTEXT" ]]; then
  AGENT_INPUT+="$REJECTION_CONTEXT"
else
  AGENT_INPUT+="(none)"$'\n'
fi

# ── Substitute min_grouping_size in agent file ─────────────────────────────
AGENT_FILE="$EVOLVE_DIR/agents/clusterer.md"
AGENT_TMP=$(mktemp)
sed "s/{min_grouping_size}/$MIN_GROUPING_SIZE/g" "$AGENT_FILE" > "$AGENT_TMP"

# ── Invoke clusterer agent ─────────────────────────────────────────────────
AGENT_OUTPUT=$(echo "$AGENT_INPUT" | invoke_agent "$AGENT_TMP" 2>/dev/null) || {
  evolve_log "cluster.sh: agent invocation failed"
  rm -f "$AGENT_TMP"
  exit 0
}
rm -f "$AGENT_TMP"

# ── Check for NONE ────────────────────────────────────────────────────────
TRIMMED_OUTPUT=$(echo "$AGENT_OUTPUT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
if [[ "$TRIMMED_OUTPUT" == "NONE" ]]; then
  evolve_log "cluster.sh: agent returned NONE"
  exit 0
fi

# ── Jaccard similarity function ────────────────────────────────────────────
# jaccard_similarity <set_a_newline_separated> <set_b_newline_separated>
# Prints the Jaccard index (intersection / union) as a decimal.
jaccard_similarity() {
  local set_a="$1"
  local set_b="$2"

  # Combine and compute union + intersection
  local union_count intersection_count
  union_count=$(printf '%s\n%s\n' "$set_a" "$set_b" | sort -u | grep -c . || echo "0")
  intersection_count=$(comm -12 <(echo "$set_a" | sort -u) <(echo "$set_b" | sort -u) | grep -c . || echo "0")

  if [[ "$union_count" -eq 0 ]]; then
    echo "0"
    return
  fi

  echo "scale=4; $intersection_count / $union_count" | bc -l
}

# ── Collect archived proposal data for overlap checks ─────────────────────
# Build arrays of: status, source_instincts (newline-separated), source_instinct_count
ARCH_STATUSES=()
ARCH_SRC_IDS=()
ARCH_SRC_COUNTS=()

if [[ -f "$ARCHIVED_PROPOSAL_INDEX" ]]; then
  ARCHIVED_COUNT=$(yq '.proposals | length' "$ARCHIVED_PROPOSAL_INDEX" 2>/dev/null || echo "0")
  for ((i=0; i<ARCHIVED_COUNT; i++)); do
    status=$(yq ".proposals[$i].status" "$ARCHIVED_PROPOSAL_INDEX")
    if [[ "$status" != "rejected" && "$status" != "permanently_rejected" ]]; then
      continue
    fi
    ARCH_STATUSES+=("$status")
    src_count=$(yq ".proposals[$i].source_instinct_count // 0" "$ARCHIVED_PROPOSAL_INDEX" 2>/dev/null || echo "0")
    ARCH_SRC_COUNTS+=("$src_count")
    src_ids=""
    sc=$(yq ".proposals[$i].source_instincts | length" "$ARCHIVED_PROPOSAL_INDEX" 2>/dev/null || echo "0")
    for ((j=0; j<sc; j++)); do
      sid=$(yq ".proposals[$i].source_instincts[$j]" "$ARCHIVED_PROPOSAL_INDEX")
      src_ids+="$sid"$'\n'
    done
    ARCH_SRC_IDS+=("$src_ids")
  done
fi

# ── Parse agent output: split on --- into YAML documents ──────────────────
# We use awk to split on lines that are exactly "---"
DOC_INDEX=0
CURRENT_DOC=""
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PROPOSALS_CREATED=0

process_document() {
  local doc="$1"
  [[ -z "$doc" ]] && return

  # Strip markdown code fences if present
  doc=$(echo "$doc" | sed '/^```yaml$/d; /^```$/d')

  # Parse fields from YAML using a temp file
  local tmp_doc
  tmp_doc=$(mktemp)
  echo "$doc" > "$tmp_doc"

  local name type title description
  name=$(yq '.name // ""' "$tmp_doc" 2>/dev/null || echo "")
  type=$(yq '.type // ""' "$tmp_doc" 2>/dev/null || echo "")
  title=$(yq '.title // ""' "$tmp_doc" 2>/dev/null || echo "")
  description=$(yq '.description // ""' "$tmp_doc" 2>/dev/null || echo "")

  # Read source_instincts as newline-separated list
  local src_instincts_raw=""
  local src_count
  src_count=$(yq '.source_instincts | length' "$tmp_doc" 2>/dev/null || echo "0")
  for ((si=0; si<src_count; si++)); do
    local sid
    sid=$(yq ".source_instincts[$si]" "$tmp_doc")
    src_instincts_raw+="$sid"$'\n'
  done

  # Read proposed_content
  local proposed_content
  proposed_content=$(yq '.proposed_content // ""' "$tmp_doc" 2>/dev/null || echo "")

  rm -f "$tmp_doc"

  # Validate required fields
  if [[ -z "$name" || -z "$type" || "$src_count" -eq 0 ]]; then
    evolve_log "cluster.sh: skipping document with missing fields (name=$name, type=$type, src_count=$src_count)"
    return
  fi

  # Validate agent-emitted identifiers BEFORE consumption (R5).
  if ! validate_id "$name"; then
    evolve_log "WARN cluster.sh: skipping document with invalid name='$name'"
    return
  fi
  if ! validate_type "$type"; then
    evolve_log "WARN cluster.sh: skipping document with invalid type='$type' (name=$name)"
    return
  fi
  while IFS= read -r _sid; do
    [[ -z "$_sid" ]] && continue
    if ! validate_id "$_sid"; then
      evolve_log "WARN cluster.sh: skipping document name='$name' -- invalid source_instinct id='$_sid'"
      return
    fi
  done <<< "$src_instincts_raw"

  # ── Overlap checks against archived proposals ───────────────────────────
  local skip=0
  local arch_total=${#ARCH_STATUSES[@]}
  if [[ "$arch_total" -gt 0 ]]; then
  for ((ai=0; ai<arch_total; ai++)); do
    local arch_status="${ARCH_STATUSES[$ai]}"
    local arch_src="${ARCH_SRC_IDS[$ai]}"
    local arch_count="${ARCH_SRC_COUNTS[$ai]}"

    local jaccard
    jaccard=$(jaccard_similarity "$src_instincts_raw" "$arch_src")

    if (( $(echo "$jaccard > $OVERLAP_THRESHOLD" | bc -l) )); then
      if [[ "$arch_status" == "permanently_rejected" ]]; then
        evolve_log "cluster.sh: skipping $name -- overlaps with permanently rejected proposal (jaccard=$jaccard)"
        skip=1
        break
      elif [[ "$arch_status" == "rejected" ]]; then
        # For rejected: only skip if current source count does not exceed the rejected count
        if [[ "$src_count" -le "$arch_count" ]]; then
          evolve_log "cluster.sh: skipping $name -- overlaps with rejected proposal and count not exceeded ($src_count <= $arch_count, jaccard=$jaccard)"
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

  # ── Generate proposal ID and write ──────────────────────────────────────
  local date_str
  date_str=$(date -u +%Y-%m-%d)
  local proposal_id="proposal-${name}-${date_str}"

  # Determine domain from first source instinct
  local first_instinct="${src_instincts_raw%%$'\n'*}"
  local domain="unknown"
  if [[ -f "$INSTINCTS_DIR/${first_instinct}.yaml" ]]; then
    domain=$(yq '.domain // "unknown"' "$INSTINCTS_DIR/${first_instinct}.yaml" 2>/dev/null || echo "unknown")
  fi

  # Defense-in-depth: validate domain read from disk against pre-Phase-2 corruption (R5).
  if ! validate_id "$domain"; then
    evolve_log "WARN cluster.sh: skipping document name='$name' -- invalid domain='$domain' on disk"
    return
  fi

  # Build source_instincts YAML list
  local src_yaml=""
  while IFS= read -r sid; do
    [[ -z "$sid" ]] && continue
    src_yaml+="  - $sid"$'\n'
  done <<< "$src_instincts_raw"

  # Write proposal file. Title and description are agent-emitted; escape
  # for YAML. proposed_content uses block-literal (|) so it does not need escaping.
  local title_esc description_esc
  title_esc=$(yaml_escape_dq "$title")
  description_esc=$(yaml_escape_dq "$description")
  local proposal_file="${name}-${type}.yaml"
  cat > "$PROPOSALS_DIR/$proposal_file" <<YAML
version: 1
id: ${proposal_id}
type: ${type}
domain: ${domain}
created: "${NOW}"
title: "${title_esc}"
description: "${description_esc}"
source_instincts:
${src_yaml}source_instinct_count: ${src_count}
proposed_content: |
$(echo "$proposed_content" | sed 's/^/  /')
status: pending
YAML

  evolve_log "cluster.sh: created proposal $proposal_id ($proposal_file)"
  PROPOSALS_CREATED=$((PROPOSALS_CREATED + 1))

  # Add to proposals index (atomic write)
  local tmp_index
  tmp_index=$(mktemp)
  yq ".proposals += [{
    \"id\": \"${proposal_id}\",
    \"type\": \"${type}\",
    \"domain\": \"${domain}\",
    \"status\": \"pending\",
    \"file\": \"${proposal_file}\"
  }]" "$PROPOSAL_INDEX" > "$tmp_index"
  mv "$tmp_index" "$PROPOSAL_INDEX"
}

# Split output on --- lines and process each document
while IFS= read -r line; do
  if [[ "$line" == "---" ]]; then
    if [[ -n "$CURRENT_DOC" ]]; then
      process_document "$CURRENT_DOC"
      DOC_INDEX=$((DOC_INDEX + 1))
    fi
    CURRENT_DOC=""
  else
    CURRENT_DOC+="$line"$'\n'
  fi
done <<< "$AGENT_OUTPUT"

# Process the last document
if [[ -n "$CURRENT_DOC" ]]; then
  process_document "$CURRENT_DOC"
fi

# ── Release lock before git push (git-sync.lock is independent) ───────────
release_lock "$LOCK_FILE"
trap - EXIT

# ── Sync to git ───────────────────────────────────────────────────────────
evolve_git_push "evolve(cluster): ${PROPOSALS_CREATED} proposal(s) created"

evolve_log "cluster.sh: done, processed $((DOC_INDEX + 1)) document(s)"
exit 0
