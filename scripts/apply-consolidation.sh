#!/usr/bin/env bash
set -euo pipefail

# apply-consolidation.sh <project_id> | --global  <cid>
#
# Applies one staged consolidation (produced by consolidate.sh). Re-validates
# the sources under the lock (aborting the cid if the pool moved during review),
# writes the merged entry, archives each source with reason=consolidated, removes
# the staging file, and git-pushes. Idempotent: a crashed apply self-heals on
# re-run (merged entry / archived sources are checked before (re)writing).
#
# Sourcing with EVOLVE_APPLY_LIB=1 defines the functions (e.g. the merge-math
# helper) without executing, for the hermetic provenance test.

source "$HOME/.claude/evolve/scripts/lib.sh"
trap 'evolve_log "ERROR ${BASH_SOURCE[0]##*/}:$LINENO (exit $?)"' ERR

# ── Merge math (instinct) ────────────────────────────────────────────────────
# compute_instinct_merge <idir> <scope> <max_confidence>
# Reads newline-separated ids from global M_SRC_IDS; sets:
#   M_CONF (min(max_confidence, max)), M_OBS (sum), M_CREATED (min),
#   M_LASTREINF (max), and either M_SESSIONS (project) or M_PROJECTS+M_SPI (global).
compute_instinct_merge() {
  local idir="$1" scope="$2" maxc="$3"
  M_CONF=0; M_OBS=0; M_CREATED=""; M_LASTREINF=""; M_SESSIONS=""; M_PROJECTS=""; M_SPI=""
  local sid f c o cr lr n k p ii
  while IFS= read -r sid; do
    [[ -z "$sid" ]] && continue
    f="$idir/${sid}.yaml"
    [[ -f "$f" ]] || continue
    c=$(yq '.confidence // 0' "$f" 2>/dev/null || echo 0)
    c=$(validate_numeric "$c" "$_NUMERIC_NONNEG_FLOAT" "0")
    if [[ "$(echo "$c > $M_CONF" | bc -l)" == "1" ]]; then M_CONF="$c"; fi
    o=$(yq '.observation_count // 0' "$f" 2>/dev/null || echo 0)
    o=$(validate_numeric "$o" "$_NUMERIC_NONNEG_INT" "0")
    M_OBS=$((M_OBS + o))
    cr=$(yq '.created // ""' "$f" 2>/dev/null || echo "")
    if [[ -n "$cr" && ( -z "$M_CREATED" || "$cr" < "$M_CREATED" ) ]]; then M_CREATED="$cr"; fi
    lr=$(yq '.last_reinforced // ""' "$f" 2>/dev/null || echo "")
    if [[ -n "$lr" && ( -z "$M_LASTREINF" || "$lr" > "$M_LASTREINF" ) ]]; then M_LASTREINF="$lr"; fi
    if [[ "$scope" == "global" ]]; then
      n=$(yq '.source_projects | length' "$f" 2>/dev/null || echo 0)
      for ((k=0; k<n; k++)); do
        p=$(yq ".source_projects[$k]" "$f" 2>/dev/null || echo "")
        [[ -z "$p" ]] && continue
        printf '%s\n' "$M_PROJECTS" | grep -qx "$p" || M_PROJECTS+="$p"$'\n'
      done
      n=$(yq '.source_project_instincts | length' "$f" 2>/dev/null || echo 0)
      for ((k=0; k<n; k++)); do
        p=$(yq ".source_project_instincts[$k].project" "$f" 2>/dev/null || echo "")
        ii=$(yq ".source_project_instincts[$k].instinct" "$f" 2>/dev/null || echo "")
        [[ -z "$p" && -z "$ii" ]] && continue
        M_SPI+="${p}|${ii}"$'\n'
      done
    else
      n=$(yq '.source_sessions | length' "$f" 2>/dev/null || echo 0)
      for ((k=0; k<n; k++)); do
        M_SESSIONS+="$(yq ".source_sessions[$k]" "$f" 2>/dev/null || echo "")"$'\n'
      done
    fi
  done <<< "$M_SRC_IDS"
  [[ -z "$M_CREATED" ]] && M_CREATED="$NOW"
  [[ -z "$M_LASTREINF" ]] && M_LASTREINF="$NOW"
  if [[ "$(echo "$M_CONF > $maxc" | bc -l)" == "1" ]]; then M_CONF="$maxc"; fi
}

# instinct_in_pending <id> -- 0 if referenced by any pending proposal.
instinct_in_pending() {
  local id="$1" pindex="$BASE_DIR/proposals/index.yaml" pcount pf pp n j
  [[ -f "$pindex" ]] || return 1
  pcount=$(yq '.proposals | length' "$pindex" 2>/dev/null || echo 0)
  for ((pj=0; pj<pcount; pj++)); do
    pf=$(yq ".proposals[$pj].file" "$pindex" 2>/dev/null || echo "")
    pp="$BASE_DIR/proposals/$pf"
    [[ -f "$pp" ]] || continue
    n=$(yq '.source_instincts | length' "$pp" 2>/dev/null || echo 0)
    for ((j=0; j<n; j++)); do [[ "$(yq ".source_instincts[$j]" "$pp")" == "$id" ]] && return 0; done
    n=$(yq '.source_global_instincts | length' "$pp" 2>/dev/null || echo 0)
    for ((j=0; j<n; j++)); do [[ "$(yq ".source_global_instincts[$j]" "$pp")" == "$id" ]] && return 0; done
  done
  return 1
}

# abort_cid <message> -- leave staging in place, tell the user to re-run analyze.
abort_cid() {
  release_lock "$LOCK_FILE" 2>/dev/null || true
  trap - EXIT
  evolve_log "apply-consolidation.sh: abort $CID -- $1"
  echo "ABORTED: $1" >&2
  echo "The source pool changed since analysis. Re-run /consolidate to refresh." >&2
  exit 3
}

# ── Instinct apply ───────────────────────────────────────────────────────────
apply_instinct() {
  local idir="$BASE_DIR/instincts"
  local index="$idir/index.yaml"
  local adir="$idir/archived" aindex="$idir/archived/index.yaml"
  local name domain trigger action
  name=$(yq '.merged_name' "$SF"); domain=$(yq '.merged_domain' "$SF")
  trigger=$(yq '.merged_trigger' "$SF"); action=$(yq '.merged_action' "$SF")
  validate_id "$name" || abort_cid "invalid merged_name '$name'"
  validate_id "$domain" || domain="unknown"

  # Recovery keys on INDEX membership (the source of truth for "applied"), not
  # file existence. A crash between the file mv and the index append leaves an
  # orphan file that is NOT yet indexed; that must re-enter the write path so the
  # index append (and a harmless file overwrite) complete. A merged entry already
  # in the index means the write finished and only source archival may remain.
  local recovery=0
  if [[ "$(yq "[.instincts[] | select(.id == \"$name\")] | length" "$index" 2>/dev/null || true)" -ne 0 ]]; then
    recovery=1
    evolve_log "apply-consolidation.sh: $CID recovery -- merged instinct '$name' already in index"
  fi

  local sid
  if [[ "$recovery" -eq 0 ]]; then
    # Fresh apply: every source must be present, in-band, and not pending.
    while IFS= read -r sid; do
      [[ -z "$sid" ]] && continue
      [[ "$sid" == "$name" ]] && abort_cid "merged_name equals source '$sid'"
      [[ -f "$idir/${sid}.yaml" ]] || abort_cid "source instinct '$sid' no longer present"
      local present
      present=$(yq "[.instincts[] | select(.id == \"$sid\")] | length" "$index" 2>/dev/null || echo 0)
      [[ "$present" -ge 1 ]] || abort_cid "source instinct '$sid' missing from live index"
      local c
      c=$(yq '.confidence // 0' "$idir/${sid}.yaml" 2>/dev/null || echo 0)
      c=$(validate_numeric "$c" "$_NUMERIC_NONNEG_FLOAT" "0")
      if [[ "$(echo "$c >= $PROPOSE_MEM_THRESHOLD" | bc -l)" == "1" ]]; then
        abort_cid "source '$sid' reached graduation threshold ($c); it is no longer consolidation-eligible"
      fi
      if instinct_in_pending "$sid"; then abort_cid "source '$sid' is now referenced by a pending proposal"; fi
    done <<< "$M_SRC_IDS"

    # Compute provenance from LIVE sources.
    compute_instinct_merge "$idir" "$SCOPE" "$MAX_CONFIDENCE"

    local cf_yaml="" prov=""
    while IFS= read -r sid; do [[ -z "$sid" ]] && continue; cf_yaml+="  - $sid"$'\n'; done <<< "$M_SRC_IDS"
    if [[ "$SCOPE" == "global" ]]; then
      prov="source_projects:"$'\n'
      local p
      while IFS= read -r p; do [[ -z "$p" ]] && continue; prov+="  - $p"$'\n'; done <<< "$M_PROJECTS"
      prov+="source_project_instincts:"$'\n'
      local line pp ii
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        pp="${line%%|*}"; ii="${line#*|}"
        prov+="  - project: $pp"$'\n'"    instinct: $ii"$'\n'
      done <<< "$M_SPI"
    else
      prov="source_sessions:"$'\n'
      local s
      while IFS= read -r s; do [[ -z "$s" ]] && continue; prov+="  - $s"$'\n'; done <<< "$M_SESSIONS"
    fi

    local tmp; tmp=$(mktemp)
    cat > "$tmp" <<YAML
version: 1
id: ${name}
trigger: "$(yaml_escape_dq "$trigger")"
action: "$(yaml_escape_dq "$action")"
confidence: ${M_CONF}
domain: ${domain}
created: "${M_CREATED}"
last_reinforced: "${M_LASTREINF}"
observation_count: ${M_OBS}
consolidated_from:
${cf_yaml}${prov}status: active
YAML
    mv "$tmp" "$idir/${name}.yaml"

    # Append to live index.
    local tmp_idx; tmp_idx=$(mktemp)
    yq ".instincts += [{
      \"id\": \"${name}\",
      \"domain\": \"${domain}\",
      \"confidence\": ${M_CONF},
      \"trigger\": \"$(yaml_escape_dq "$trigger")\",
      \"file\": \"${name}.yaml\"
    }]" "$index" > "$tmp_idx"
    mv "$tmp_idx" "$index"
    evolve_log "apply-consolidation.sh: wrote merged instinct '$name' (conf=$M_CONF, obs=$M_OBS)"
  fi

  # Archive each source. Each step (file move, live-index removal, archived-index
  # append) is independently idempotent so a partial archive self-heals on re-run
  # (mirrors approve-proposal.sh, including the archived-index repair branch).
  while IFS= read -r sid; do
    [[ -z "$sid" ]] && continue
    local ifile="$idir/${sid}.yaml" afile="$adir/${sid}.yaml" idom="unknown"
    if [[ -f "$ifile" ]]; then
      idom=$(yq '.domain // "unknown"' "$ifile" 2>/dev/null || echo "unknown")
      local tmp_inst; tmp_inst=$(mktemp)
      yq ".archived_reason = \"consolidated\" | .archived_by = \"${CID}\" | .archived_at = \"${NOW}\"" "$ifile" > "$tmp_inst"
      mv "$tmp_inst" "$afile"; rm -f "$ifile"
    elif [[ -f "$afile" ]]; then
      local aby; aby=$(yq '.archived_by // ""' "$afile" 2>/dev/null || echo "")
      if [[ "$aby" != "$CID" ]]; then
        evolve_log "WARN apply-consolidation.sh: source '$sid' archived by other '$aby' -- skipping"
        continue
      fi
      idom=$(yq '.domain // "unknown"' "$afile" 2>/dev/null || echo "unknown")
    else
      evolve_log "WARN apply-consolidation.sh: source '$sid' missing from live and archived -- skipping"
      continue
    fi
    # Remove from live index if still present.
    if [[ "$(yq "[.instincts[] | select(.id == \"$sid\")] | length" "$index" 2>/dev/null || true)" -ne 0 ]]; then
      local tmp_li; tmp_li=$(mktemp)
      yq ".instincts = [.instincts[] | select(.id != \"${sid}\")]" "$index" > "$tmp_li"; mv "$tmp_li" "$index"
    fi
    # Append to archived index if missing (repairs a partial prior run).
    if [[ "$(yq "[.instincts[] | select(.id == \"$sid\")] | length" "$aindex" 2>/dev/null || true)" -eq 0 ]]; then
      local tmp_ai; tmp_ai=$(mktemp)
      yq ".instincts += [{
        \"id\": \"${sid}\",
        \"domain\": \"${idom}\",
        \"archived_reason\": \"consolidated\",
        \"archived_by\": \"${CID}\",
        \"archived_at\": \"${NOW}\",
        \"file\": \"${sid}.yaml\"
      }]" "$aindex" > "$tmp_ai"; mv "$tmp_ai" "$aindex"
    fi
  done <<< "$M_SRC_IDS"

  RESULT="consolidated $(printf '%s' "$M_SRC_IDS" | grep -c . || true) instinct(s) into ${name}"
}

# ── Memory apply ─────────────────────────────────────────────────────────────
apply_memory() {
  local mdir="$BASE_DIR/memory"
  local index="$mdir/index.yaml"
  local adir="$mdir/archived" aindex="$mdir/archived/index.yaml"
  mkdir -p "$adir"
  [[ -f "$aindex" ]] || printf 'version: 1\nmemories: []\n' > "$aindex"
  local name title description mem_id
  name=$(yq '.merged_name' "$SF"); title=$(yq '.merged_title' "$SF"); description=$(yq '.merged_description' "$SF")
  validate_id "$name" || abort_cid "invalid merged_name '$name'"
  mem_id="${MEM_PREFIX}${name}"

  # Recovery keys on INDEX membership (not the .md file), so an orphan .md from a
  # crash before the index append re-enters the write path and self-heals.
  local recovery=0
  local existing
  existing=$(yq "[.memories[] | select(.id == \"$mem_id\")] | length" "$index" 2>/dev/null || echo 0)
  if [[ "$existing" -ne 0 ]]; then
    recovery=1
    evolve_log "apply-consolidation.sh: $CID recovery -- merged memory '$mem_id' already in index"
  fi

  local sid
  if [[ "$recovery" -eq 0 ]]; then
    while IFS= read -r sid; do
      [[ -z "$sid" ]] && continue
      [[ "$sid" == "$mem_id" ]] && abort_cid "merged id equals source '$sid'"
      local present
      present=$(yq "[.memories[] | select(.id == \"$sid\")] | length" "$index" 2>/dev/null || echo 0)
      [[ "$present" -ge 1 ]] || abort_cid "source memory '$sid' no longer present"
    done <<< "$M_SRC_IDS"

    # Write the merged artifact via write-artifact.sh (handles global- prefix + no-clobber).
    local cfile; cfile=$(mktemp)
    yq '.merged_content // ""' "$SF" > "$cfile"
    if [[ ! -s "$cfile" ]]; then rm -f "$cfile"; abort_cid "empty merged_content"; fi
    # Reuse an orphan .md left by a prior crash (write-artifact.sh is no-clobber);
    # otherwise write it fresh.
    if [[ -e "$mdir/${mem_id}.md" ]]; then
      evolve_log "apply-consolidation.sh: $CID reusing existing memory file '${mem_id}.md' (recovery)"
    else
      "$EVOLVE_DIR/scripts/write-artifact.sh" --scope "$SCOPE" "" memory "$name" "$cfile" "$PROJECT_ID" >/dev/null
    fi
    rm -f "$cfile"

    local src_yaml=""
    while IFS= read -r sid; do [[ -z "$sid" ]] && continue; src_yaml+="\"${sid}\", "; done <<< "$M_SRC_IDS"
    src_yaml="${src_yaml%, }"
    local tmp_mi; tmp_mi=$(mktemp)
    yq ".memories += [{
      \"id\": \"${mem_id}\",
      \"file\": \"${mem_id}.md\",
      \"title\": \"$(yaml_escape_dq "$title")\",
      \"description\": \"$(yaml_escape_dq "$description")\",
      \"source_proposal\": \"${CID}\",
      \"source_memories\": [${src_yaml}],
      \"created\": \"${NOW}\"
    }]" "$index" > "$tmp_mi"
    mv "$tmp_mi" "$index"
    evolve_log "apply-consolidation.sh: wrote merged memory '$mem_id'"
  fi

  # Archive each source memory (idempotent).
  while IFS= read -r sid; do
    [[ -z "$sid" ]] && continue
    local present
    present=$(yq "[.memories[] | select(.id == \"$sid\")] | length" "$index" 2>/dev/null || echo 0)
    [[ "$present" -eq 0 ]] && continue
    local sfile stitle
    sfile=$(yq ".memories[] | select(.id == \"$sid\") | .file" "$index" 2>/dev/null || echo "")
    stitle=$(yq ".memories[] | select(.id == \"$sid\") | .title // \"\"" "$index" 2>/dev/null || echo "")
    if [[ -n "$sfile" && -f "$mdir/$sfile" ]]; then mv "$mdir/$sfile" "$adir/$sfile"; fi
    local tmp_li; tmp_li=$(mktemp)
    yq ".memories = [.memories[] | select(.id != \"${sid}\")]" "$index" > "$tmp_li"; mv "$tmp_li" "$index"
    local tmp_ai; tmp_ai=$(mktemp)
    yq ".memories += [{
      \"id\": \"${sid}\",
      \"file\": \"${sfile}\",
      \"title\": \"$(yaml_escape_dq "$stitle")\",
      \"archived_reason\": \"consolidated\",
      \"archived_by\": \"${CID}\",
      \"archived_at\": \"${NOW}\"
    }]" "$aindex" > "$tmp_ai"; mv "$tmp_ai" "$aindex"
  done <<< "$M_SRC_IDS"

  RESULT="consolidated $(printf '%s' "$M_SRC_IDS" | grep -c . || true) memory(ies) into ${mem_id}"
}

# ── Proposal apply (project scope, skill/rule) ───────────────────────────────
apply_proposal() {
  local pdir="$BASE_DIR/proposals"
  local index="$pdir/index.yaml"
  local adir="$pdir/archived" aindex="$pdir/archived/index.yaml"
  local name mtype title description
  name=$(yq '.merged_name' "$SF"); mtype=$(yq '.merged_type' "$SF")
  title=$(yq '.merged_title' "$SF"); description=$(yq '.merged_description' "$SF")
  validate_id "$name" || abort_cid "invalid merged_name '$name'"
  [[ "$mtype" == "skill" || "$mtype" == "rule" ]] || abort_cid "merged_type '$mtype' not skill/rule"

  local mfile="${name}-${mtype}.yaml"
  local recovery=0
  local existing
  # Recovery keys on INDEX membership (not the file), so an orphan proposal file
  # from a crash before the index append re-enters the write path (the mv below
  # harmlessly overwrites it) and self-heals.
  existing=$(yq "[.proposals[] | select(.file == \"$mfile\")] | length" "$index" 2>/dev/null || echo 0)
  if [[ "$existing" -ne 0 ]]; then
    recovery=1
    evolve_log "apply-consolidation.sh: $CID recovery -- merged proposal '$mfile' already in index"
  fi

  local sid domain="unknown"
  if [[ "$recovery" -eq 0 ]]; then
    # Verify every source is pending, of type mtype; capture domain from the first.
    local first=1
    while IFS= read -r sid; do
      [[ -z "$sid" ]] && continue
      local spf; spf=$(yq ".proposals[] | select(.id == \"$sid\") | .file" "$index" 2>/dev/null || echo "")
      [[ -n "$spf" ]] || abort_cid "source proposal '$sid' no longer pending"
      [[ -f "$pdir/$spf" ]] || abort_cid "source proposal file missing for '$sid'"
      local st; st=$(yq '.type // ""' "$pdir/$spf" 2>/dev/null || echo "")
      [[ "$st" == "$mtype" ]] || abort_cid "source '$sid' type '$st' != '$mtype'"
      if [[ "$first" -eq 1 ]]; then
        domain=$(yq '.domain // "unknown"' "$pdir/$spf" 2>/dev/null || echo "unknown")
        validate_id "$domain" || domain="unknown"
        first=0
      fi
    done <<< "$M_SRC_IDS"

    # Union of source_instincts from staging (computed at analysis time).
    local inst_yaml="" icount ii
    icount=$(yq '.merged_source_instinct_count // 0' "$SF" 2>/dev/null || echo 0)
    local n j
    n=$(yq '.merged_source_instincts | length' "$SF" 2>/dev/null || echo 0)
    for ((j=0; j<n; j++)); do
      ii=$(yq ".merged_source_instincts[$j]" "$SF" 2>/dev/null || echo "")
      [[ -z "$ii" ]] && continue
      inst_yaml+="  - $ii"$'\n'
    done

    local cfile; cfile=$(mktemp)
    yq '.merged_proposed_content // ""' "$SF" > "$cfile"
    if [[ ! -s "$cfile" ]]; then rm -f "$cfile"; abort_cid "empty merged_proposed_content"; fi

    local pid="proposal-${name}-${EPOCH_CID}"
    local tmp; tmp=$(mktemp)
    {
      cat <<YAML
version: 1
id: ${pid}
name: ${name}
type: ${mtype}
domain: ${domain}
created: "${NOW}"
title: "$(yaml_escape_dq "$title")"
description: "$(yaml_escape_dq "$description")"
source_instincts:
${inst_yaml}source_instinct_count: ${icount}
proposed_content: |
YAML
      sed 's/^/  /' "$cfile"
      printf 'status: pending\n'
    } > "$tmp"
    rm -f "$cfile"
    mv "$tmp" "$pdir/$mfile"

    local tmp_idx; tmp_idx=$(mktemp)
    yq ".proposals += [{
      \"id\": \"${pid}\",
      \"type\": \"${mtype}\",
      \"domain\": \"${domain}\",
      \"status\": \"pending\",
      \"file\": \"${mfile}\"
    }]" "$index" > "$tmp_idx"
    mv "$tmp_idx" "$index"
    evolve_log "apply-consolidation.sh: wrote merged proposal '$pid' ($mfile)"
  fi

  # Archive each source proposal as consolidated (reuses archive_proposal()).
  while IFS= read -r sid; do
    [[ -z "$sid" ]] && continue
    local spf; spf=$(yq ".proposals[] | select(.id == \"$sid\") | .file" "$index" 2>/dev/null || echo "")
    [[ -z "$spf" ]] && continue   # already archived
    archive_proposal "$pdir/$spf" "$sid" "$adir" "$aindex" "$index" "consolidated" || \
      evolve_log "WARN apply-consolidation.sh: archive_proposal failed for '$sid'"
  done <<< "$M_SRC_IDS"

  RESULT="consolidated $(printf '%s' "$M_SRC_IDS" | grep -c . || true) ${mtype} proposal(s) into ${name}"
}

# When sourced for testing, stop here.
if [[ "${EVOLVE_APPLY_LIB:-}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

# ── Arguments / scope ────────────────────────────────────────────────────────
if [[ "${1:-}" == "--global" ]]; then
  SCOPE="global"; PROJECT_ID=""; CID="${2:?usage: apply-consolidation.sh --global <cid>}"
elif [[ -n "${1:-}" && -n "${2:-}" ]]; then
  SCOPE="project"; PROJECT_ID="$1"; CID="$2"
else
  echo "usage: apply-consolidation.sh <project_id>|--global <cid>" >&2
  exit 1
fi
validate_id "$CID" || { echo "apply-consolidation.sh: invalid cid '$CID'" >&2; exit 1; }
[[ "$CID" == consolidation-* ]] || { echo "apply-consolidation.sh: not a consolidation id '$CID'" >&2; exit 1; }
# EPOCH_CID = trailing epoch of the cid (used for derived proposal ids).
EPOCH_CID="${CID##*-}"

if [[ "$SCOPE" == "global" ]]; then
  init_global
  BASE_DIR="$GLOBAL_DIR"; LOCK_FILE="$GLOBAL_DIR/global.lock"
  CONF_PID=""; MEM_PREFIX="global-"
  PROP_THRESH_PATH='.global_instincts.propose_memory_threshold // 0.85'
  MAXC_PATH='.global_instincts.max_confidence // 1'
  STAGING_DIR="$EVOLVE_DIR/consolidations/global"
else
  validate_id "$PROJECT_ID" || { echo "apply-consolidation.sh: invalid project id" >&2; exit 1; }
  init_project "$PROJECT_ID"
  BASE_DIR="$EVOLVE_DIR/projects/$PROJECT_ID"; LOCK_FILE="$BASE_DIR/evolve.lock"
  CONF_PID="$PROJECT_ID"; MEM_PREFIX=""
  PROP_THRESH_PATH='.instincts.propose_memory_threshold // 0.85'
  MAXC_PATH='.instincts.max_confidence // 1'
  STAGING_DIR="$EVOLVE_DIR/consolidations/$PROJECT_ID"
fi

SF="$STAGING_DIR/${CID}.yaml"
if [[ ! -f "$SF" ]]; then
  echo "apply-consolidation.sh: staging file not found: $SF" >&2
  exit 1
fi

PROPOSE_MEM_THRESHOLD=$(read_config "$PROP_THRESH_PATH" "$CONF_PID" 2>/dev/null || echo "0.85")
PROPOSE_MEM_THRESHOLD=$(validate_numeric "$PROPOSE_MEM_THRESHOLD" "$_NUMERIC_NONNEG_FLOAT" "0.85")
MAX_CONFIDENCE=$(read_config "$MAXC_PATH" "$CONF_PID" 2>/dev/null || echo "1")
MAX_CONFIDENCE=$(validate_numeric "$MAX_CONFIDENCE" "$_NUMERIC_NONNEG_FLOAT" "1")
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── Acquire lock (block; approval must wait, not skip) ───────────────────────
if ! acquire_lock_blocking "$LOCK_FILE" 30; then
  echo "apply-consolidation.sh: lock busy, try again shortly" >&2
  exit 1
fi
trap 'release_lock "$LOCK_FILE" 2>/dev/null' EXIT

# ── Load staging + dispatch ──────────────────────────────────────────────────
ENTRY_TYPE=$(yq '.entry_type' "$SF" 2>/dev/null || echo "")
STAGE_SCOPE=$(yq '.scope' "$SF" 2>/dev/null || echo "")
if [[ "$STAGE_SCOPE" != "$SCOPE" ]]; then
  release_lock "$LOCK_FILE"; trap - EXIT
  echo "apply-consolidation.sh: scope mismatch (staging=$STAGE_SCOPE, arg=$SCOPE)" >&2
  exit 1
fi

# M_SRC_IDS: newline-separated source ids, used by all handlers + merge math.
M_SRC_IDS=""
SRC_N=$(yq '.source_ids | length' "$SF" 2>/dev/null || echo 0)
for ((i=0; i<SRC_N; i++)); do M_SRC_IDS+="$(yq ".source_ids[$i]" "$SF")"$'\n'; done

RESULT=""
case "$ENTRY_TYPE" in
  instinct) apply_instinct ;;
  memory)   apply_memory ;;
  proposal)
    [[ "$SCOPE" == "project" ]] || { release_lock "$LOCK_FILE"; trap - EXIT; echo "proposal consolidation is project-scope only" >&2; exit 1; }
    apply_proposal ;;
  *)
    release_lock "$LOCK_FILE"; trap - EXIT
    echo "apply-consolidation.sh: unknown entry_type '$ENTRY_TYPE'" >&2
    exit 1 ;;
esac

# ── Success: remove staging, release, push ───────────────────────────────────
rm -f "$SF"
release_lock "$LOCK_FILE"
trap - EXIT
evolve_git_push "evolve(consolidate): applied ${CID}"
evolve_log "apply-consolidation.sh: applied ${CID} (${RESULT})"
echo "$RESULT"
exit 0
