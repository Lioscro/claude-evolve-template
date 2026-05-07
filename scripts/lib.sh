#!/usr/bin/env bash
set -euo pipefail

# ── Constants ───────────────────────────────────────────────────────────────
EVOLVE_DIR="$HOME/.claude/evolve"
EVOLVE_CONFIG="$EVOLVE_DIR/config.yaml"
EVOLVE_LOG="$EVOLVE_DIR/evolve.log"
GLOBAL_DIR="$EVOLVE_DIR/global"

# ── Arithmetic ─────────────────────────────────────────────────────────────
# macOS bc -l omits the leading zero for numbers < 1 (outputs .45 not 0.45).
# yq interprets .45 as a path expression, not a number, so assignments silently
# become no-ops. This wrapper ensures a leading zero.

bc_calc() {
  echo "$1" | bc -l | sed '/^\./s/^/0/; /^-\./s/^-\./-0./'
}

# ── Numeric validation ─────────────────────────────────────────────────────
# Regex constants for caller use.
_NUMERIC_NONNEG_FLOAT='^[0-9]+(\.[0-9]+)?$'
_NUMERIC_NONNEG_INT='^[0-9]+$'

# validate_numeric <value> <regex> <fallback>
# Trims surrounding whitespace, returns the trimmed value if it matches,
# otherwise the fallback. Used to defend bc/jq/sed/heredoc sites against
# null/empty/garbage values from read_config.
validate_numeric() {
  local v="$1"
  local re="$2"
  local fallback="$3"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  if [[ "$v" =~ $re ]]; then
    printf '%s' "$v"
  else
    printf '%s' "$fallback"
  fi
}

# ── YAML escaping ──────────────────────────────────────────────────────────
# Escape a value for safe inclusion in a YAML/JSON double-quoted scalar.
# Order matters: backslash MUST be escaped before quote and newline. Used both
# in heredocs (`trigger: "$(yaml_escape_dq "$x")"`) and in yq query strings
# (`yq ".trigger = \"$(yaml_escape_dq "$x")\""`), since YAML double-quoted
# escape rules and yq's JSON-style string escapes are the same.

yaml_escape_dq() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# ── Identifier validation ──────────────────────────────────────────────────
# Pure predicates for sanitizing agent-emitted identifiers and types before
# they flow into filenames, yq queries, or YAML insertions. Return 0 on
# match, 1 otherwise; no stdout/stderr.
#
# _EVOLVE_ID_REGEX must NOT be quoted on the RHS of =~ in bash 3.2 --
# quoting causes a literal-string match. Always: [[ "$x" =~ $_EVOLVE_ID_REGEX ]]
_EVOLVE_ID_REGEX='^[a-z0-9][a-z0-9_-]{0,79}$'
_EVOLVE_TYPES_RE='^(skill|rule|memory|promotion)$'

validate_id() { [[ "$1" =~ $_EVOLVE_ID_REGEX ]]; }
validate_type() { [[ "$1" =~ $_EVOLVE_TYPES_RE ]]; }

# ── Logging ─────────────────────────────────────────────────────────────────

evolve_log() {
  local msg="$*"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "[$ts] $msg" >> "$EVOLVE_LOG" 2>/dev/null || true
}

# ── Error trap ──────────────────────────────────────────────────────────────
# Hook scripts must never block Claude. Trap ERR, log, and exit 0.

evolve_trap() {
  local lineno="${1:-unknown}"
  local code="${2:-unknown}"
  local script="${BASH_SOURCE[1]:-unknown}"
  evolve_log "ERROR in $script:$lineno (exit $code)"
  exit 0
}

# ── Subprocess detection ────────────────────────────────────────────────────
# Returns 0 (true) if running inside an evolve agent subprocess.
# Hook entrypoints call this and exit early to prevent recursive hook execution.

evolve_is_subprocess() {
  [[ "${EVOLVE_SUBPROCESS:-}" == "1" ]]
}

# ── Enabled check ──────────────────────────────────────────────────────────

evolve_enabled() {
  local enabled
  enabled="$(yq '.observer.enabled' "$EVOLVE_CONFIG" 2>/dev/null)" || enabled="true"
  # yq outputs "null" if key is missing, "true"/"false" otherwise
  if [[ "$enabled" == "false" ]]; then
    return 1
  fi
  return 0
}

# ── Config reading ──────────────────────────────────────────────────────────
# read_config <yq_path> [project_id]
# Reads a config value. If project_id is given and a per-project config.yaml
# exists, merges it on top of the global config (project wins).

read_config() {
  local yq_path="$1"
  local project_id="${2:-}"
  local result=""

  if [[ -n "$project_id" ]]; then
    local project_config="$EVOLVE_DIR/projects/$project_id/config.yaml"
    if [[ -f "$project_config" ]]; then
      result="$(yq ea "select(fi == 0) * select(fi == 1) | $yq_path" \
        "$EVOLVE_CONFIG" "$project_config" 2>/dev/null)"
      if [[ -n "$result" && "$result" != "null" ]]; then
        printf '%s\n' "$result"
        return
      fi
    fi
  fi

  # Fall back to global-only
  result="$(yq "$yq_path" "$EVOLVE_CONFIG" 2>/dev/null)"
  if [[ -n "$result" && "$result" != "null" ]]; then
    printf '%s\n' "$result"
  fi
}

# ── Project resolution ──────────────────────────────────────────────────────
# resolve_project <cwd>
# Returns a project_id string. Fallback chain:
#   1. Normalized git origin remote URL
#   2. Root commit hash
#   3. Absolute path with / replaced by _

resolve_project() {
  local cwd="$1"
  local remote
  remote="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
  if [[ -n "$remote" ]]; then
    local n="$remote"
    # 1. Strip scheme.
    n="$(echo "$n" | sed -E 's#^(ssh|git\+ssh|git|https?|ftps?|file|rsync)://##')"
    # 2. Strip userinfo "user[:pass]@" — anchored, before any /.
    #    Must precede port/SCP because userinfo's : would otherwise be
    #    misread as port or SCP separator.
    n="$(echo "$n" | sed -E 's#^[^/@]*@##')"
    # 3. Strip "host:NNNN" port (digits-only after :) before any path slash.
    n="$(echo "$n" | sed -E 's#^([^/:]+):[0-9]+(/|$)#\1\2#')"
    # 4. Convert remaining "host:path" SCP form to "host/path".
    n="$(echo "$n" | sed -E 's#^([^/:]+):#\1/#')"
    # 5. Trim leading / (file://) and trailing /.
    n="$(echo "$n" | sed -E 's#^/+##; s#/+$##')"
    # 6. Strip trailing .git.
    n="$(echo "$n" | sed -E 's#\.git$##')"
    # 7. Lowercase host segment only.
    local host="${n%%/*}"
    local rest=""
    if [[ "$n" == */* ]]; then
      rest="/${n#*/}"
    fi
    host="$(echo "$host" | tr '[:upper:]' '[:lower:]')"
    n="${host}${rest}"
    # 8. Replace / with _.
    echo "$n" | tr '/' '_'
    return
  fi
  local root_commit
  root_commit="$(git -C "$cwd" rev-list --max-parents=0 HEAD 2>/dev/null | head -1 || true)"
  if [[ -n "$root_commit" ]]; then
    echo "$root_commit"
    return
  fi
  local abs_path
  abs_path="$(cd "$cwd" && pwd)"
  echo "${abs_path:1}" | tr '/' '_'
}

# ── Project initialization ──────────────────────────────────────────────────
# init_project <project_id>
# Creates the project directory structure. Idempotent.

init_project() {
  local project_id="$1"
  local project_dir="$EVOLVE_DIR/projects/$project_id"

  mkdir -p \
    "$project_dir/observations" \
    "$project_dir/observations/archived" \
    "$project_dir/instincts" \
    "$project_dir/instincts/archived" \
    "$project_dir/proposals" \
    "$project_dir/proposals/archived" \
    "$project_dir/memory" \
    "$project_dir/memory/archived"

  # Write versioned empty index files if they don't exist
  if [[ ! -f "$project_dir/instincts/index.yaml" ]]; then
    cat > "$project_dir/instincts/index.yaml" <<'YAML'
version: 1
instincts: []
YAML
  fi

  if [[ ! -f "$project_dir/instincts/archived/index.yaml" ]]; then
    cat > "$project_dir/instincts/archived/index.yaml" <<'YAML'
version: 1
instincts: []
YAML
  fi

  if [[ ! -f "$project_dir/proposals/index.yaml" ]]; then
    cat > "$project_dir/proposals/index.yaml" <<'YAML'
version: 1
proposals: []
YAML
  fi

  if [[ ! -f "$project_dir/proposals/archived/index.yaml" ]]; then
    cat > "$project_dir/proposals/archived/index.yaml" <<'YAML'
version: 1
proposals: []
YAML
  fi

  if [[ ! -f "$project_dir/memory/index.yaml" ]]; then
    cat > "$project_dir/memory/index.yaml" <<'YAML'
version: 1
memories: []
YAML
  fi

  if [[ ! -f "$project_dir/memory/archived/index.yaml" ]]; then
    cat > "$project_dir/memory/archived/index.yaml" <<'YAML'
version: 1
memories: []
YAML
  fi
}

# ── Global initialization ──────────────────────────────────────────────────
# init_global
# Creates the global instinct/proposal directory structure. Idempotent.
# Warns via evolve_log (never stdout) if $GLOBAL_DIR is not a symlink.

init_global() {
  if [[ ! -d "$GLOBAL_DIR" ]]; then
    return 0
  fi

  if [[ ! -L "$GLOBAL_DIR" ]]; then
    evolve_log "WARN init_global: $GLOBAL_DIR exists but is not a symlink"
  fi

  mkdir -p \
    "$GLOBAL_DIR/instincts" \
    "$GLOBAL_DIR/instincts/archived" \
    "$GLOBAL_DIR/proposals" \
    "$GLOBAL_DIR/proposals/archived" \
    "$GLOBAL_DIR/memory" \
    "$GLOBAL_DIR/memory/archived"

  if [[ ! -f "$GLOBAL_DIR/instincts/index.yaml" ]]; then
    cat > "$GLOBAL_DIR/instincts/index.yaml" <<'YAML'
version: 1
instincts: []
last_promote_run: ""
YAML
  fi

  if [[ ! -f "$GLOBAL_DIR/instincts/archived/index.yaml" ]]; then
    cat > "$GLOBAL_DIR/instincts/archived/index.yaml" <<'YAML'
version: 1
instincts: []
YAML
  fi

  if [[ ! -f "$GLOBAL_DIR/proposals/index.yaml" ]]; then
    cat > "$GLOBAL_DIR/proposals/index.yaml" <<'YAML'
version: 1
proposals: []
YAML
  fi

  if [[ ! -f "$GLOBAL_DIR/proposals/archived/index.yaml" ]]; then
    cat > "$GLOBAL_DIR/proposals/archived/index.yaml" <<'YAML'
version: 1
proposals: []
YAML
  fi

  if [[ ! -f "$GLOBAL_DIR/memory/index.yaml" ]]; then
    cat > "$GLOBAL_DIR/memory/index.yaml" <<'YAML'
version: 1
memories: []
YAML
  fi

  if [[ ! -f "$GLOBAL_DIR/memory/archived/index.yaml" ]]; then
    cat > "$GLOBAL_DIR/memory/archived/index.yaml" <<'YAML'
version: 1
memories: []
YAML
  fi
}

# ── Agent invocation ────────────────────────────────────────────────────────
# invoke_agent <agent_file>
# Reads stdin, strips YAML frontmatter from agent file, invokes claude -p.
# Returns the agent's stdout.

invoke_agent() {
  local agent_file="$1"
  local tmp_system
  tmp_system="$(mktemp)"

  # Clean up temp file on exit from this function's scope
  trap 'rm -f "$tmp_system"' RETURN

  # Extract model from YAML frontmatter
  local frontmatter
  frontmatter="$(sed -n '/^---$/,/^---$/p' "$agent_file")"
  local model
  if [[ -n "${EVOLVE_AGENT_MODEL_OVERRIDE:-}" ]]; then
    model="$EVOLVE_AGENT_MODEL_OVERRIDE"
  else
    model="$(echo "$frontmatter" | yq '.model // "claude-haiku-4-5"' | head -1)"
  fi

  # Strip frontmatter (everything between first --- and second ---), write body to temp file
  # If file doesn't start with ---, copy entire file as-is.
  if head -1 "$agent_file" | grep -q '^---$'; then
    # Skip from line 1 to the second --- line
    awk 'BEGIN{skip=1} /^---$/{if(skip){count++; if(count==2){skip=0; next}} } !skip{print}' \
      "$agent_file" > "$tmp_system"
  else
    cp "$agent_file" "$tmp_system"
  fi

  # Invoke claude with EVOLVE_SUBPROCESS to prevent recursive hooks
  EVOLVE_SUBPROCESS=1 claude -p \
    --system-prompt-file "$tmp_system" \
    --model "$model" \
    --no-session-persistence
}

# ── Blocking lock acquisition ───────────────────────────────────────────────
# acquire_lock_blocking <lock_file> [timeout_seconds]
# Like acquire_lock but blocks up to timeout_seconds (default 30) instead of
# returning immediately on contention. Uses fd 9 (same slot as acquire_lock);
# release_lock works for both.

acquire_lock_blocking() {
  local lock_file="$1"
  local timeout="${2:-30}"
  exec 9>"$lock_file"
  flock -w "$timeout" 9 || return 1
  echo $$ >&9
}

# ── archive_proposal() ──────────────────────────────────────────────────────
# archive_proposal <proposal_file_path> <archive_dir> <archived_index_path> <live_index_path> <new_status>
#
# Moves a pending proposal to its archived directory, removes it from the live
# index, and appends an 8-field entry to the archived index. Idempotent:
# recovery branch detects already-moved files; index updates self-heal on re-run.
# Caller is responsible for holding the appropriate lock before calling.
#
# Returns 0 on success or recovery. Returns 1 only if the proposal is missing
# from both the live path and the archived path.

archive_proposal() {
  local proposal_file_path="$1"
  local archive_dir="$2"
  local archived_index_path="$3"
  local live_index_path="$4"
  local new_status="$5"

  local basename_file
  basename_file="$(basename "$proposal_file_path")"
  local archived_path="$archive_dir/$basename_file"

  local resolved_at
  resolved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ ! -f "$proposal_file_path" ]]; then
    # Recovery branch: source file already moved to archived path by a prior partial run.
    if [[ -f "$archived_path" ]]; then
      evolve_log "INFO archive_proposal: recovery -- $basename_file already at archived path, skipping file move"
      # Fall through to index updates using the already-archived file.
    else
      # Missing from both paths.
      evolve_log "ERROR archive_proposal: proposal not found at $proposal_file_path or $archived_path"
      return 1
    fi
  else
    # Normal branch: write status+resolved_at to temp file, mv to archived, rm original.
    local tmp_prop
    tmp_prop="$(mktemp)"
    yq "
      .status = \"${new_status}\" |
      .resolved_at = \"${resolved_at}\"
    " "$proposal_file_path" > "$tmp_prop"
    mv "$tmp_prop" "$archived_path"
    rm -f "$proposal_file_path"
  fi

  # Read proposal_id from archived copy.
  local proposal_id
  proposal_id="$(yq '.id // ""' "$archived_path")"
  if [[ -z "$proposal_id" ]]; then
    proposal_id="${basename_file%.yaml}"
    evolve_log "WARN archive_proposal: .id missing from $basename_file; falling back to filename: $proposal_id"
  fi

  # Read source_instincts array from archived copy.
  local src_count
  src_count="$(yq '.source_instincts | length' "$archived_path" 2>/dev/null || echo "0")"
  local src_instincts=()
  for ((i=0; i<src_count; i++)); do
    src_instincts+=("$(yq ".source_instincts[$i]" "$archived_path")")
  done

  # Build comma-separated quoted YAML list of source instinct ids (bash 3.2 safe).
  local src_instinct_yaml=""
  for si in ${src_instincts[@]+"${src_instincts[@]}"}; do
    src_instinct_yaml+="\"${si}\", "
  done
  src_instinct_yaml="${src_instinct_yaml%, }"

  # Read type and domain from archived copy.
  local prop_type
  prop_type="$(yq '.type // ""' "$archived_path")"
  local prop_domain
  prop_domain="$(yq '.domain // "unknown"' "$archived_path")"

  # Atomic-rewrite live index removing the proposal entry by id.
  if [[ -f "$live_index_path" ]]; then
    local tmp_live
    tmp_live="$(mktemp)"
    if ! yq ".proposals = [.proposals[] | select(.id != \"${proposal_id}\")]" "$live_index_path" > "$tmp_live"; then
      evolve_log "ERROR archive_proposal: failed to rewrite live index for $proposal_id (continuing)"
      rm -f "$tmp_live"
    else
      mv "$tmp_live" "$live_index_path"
    fi
  fi

  # Idempotency guard: check if archived index already has this entry.
  if [[ -f "$archived_index_path" ]]; then
    local already_count
    already_count="$(yq "[.proposals[] | select(.id == \"${proposal_id}\")] | length" "$archived_index_path" 2>/dev/null || echo "0")"
    if [[ "$already_count" -gt 0 ]]; then
      evolve_log "INFO archive_proposal: archived index already has entry for $proposal_id; skipping append"
      return 0
    fi
  fi

  # Atomic-append to archived index with the 8-field shape.
  if [[ -f "$archived_index_path" ]]; then
    local tmp_arch
    tmp_arch="$(mktemp)"
    if ! yq ".proposals += [{
      \"id\": \"${proposal_id}\",
      \"type\": \"${prop_type}\",
      \"domain\": \"${prop_domain}\",
      \"status\": \"${new_status}\",
      \"resolved_at\": \"${resolved_at}\",
      \"source_instincts\": [${src_instinct_yaml}],
      \"source_instinct_count\": ${src_count},
      \"file\": \"${basename_file}\"
    }]" "$archived_index_path" > "$tmp_arch"; then
      evolve_log "ERROR archive_proposal: failed to append to archived index for $proposal_id (continuing)"
      rm -f "$tmp_arch"
    else
      mv "$tmp_arch" "$archived_index_path"
    fi
  fi

  return 0
}

# ── Locking ─────────────────────────────────────────────────────────────────
# acquire_lock <lock_file>  -- returns 0 on success, 1 if already held
# release_lock <lock_file>  -- releases the lock
#
# Project and global locks share fd 9 (acquire_lock); writer locks live on
# fd 7 (acquire_writer_lock); git-sync lives on fd 8 (evolve_git_push).
# Within a single process you cannot hold two fd-9 locks simultaneously
# (the second silently overrides the first), but fd 7 and fd 9 may be
# held concurrently — used by observe.sh during snapshot phase.

acquire_lock() {
  local lock_file="$1"
  exec 9>"$lock_file"
  flock -n 9 || return 1
  echo $$ >&9
}

release_lock() {
  exec 9>&-
}

# ── Writer locks (fd 7) ─────────────────────────────────────────────────────
# Per-file blocking lock for fast-path writers (record-observation.sh) and
# observe.sh's snapshot phase. Distinct fd (7) from project/global locks (9)
# and git-sync lock (8) so they may be held concurrently with the project lock.

acquire_writer_lock() {
  local lock_file="$1"
  local timeout="${2:-5}"
  exec 7>"$lock_file"
  flock -x -w "$timeout" 7 || return 1
  return 0
}

release_writer_lock() {
  exec 7>&-
}

# ── Git sync ───────────────────────────────────────────────────────────────
# Best-effort git pull/push for cross-machine sync of instincts/proposals.
# The projects directory is symlinked from <repo>/data/projects/.

evolve_repo_root() {
  local target
  target=$(readlink "$EVOLVE_DIR/projects" 2>/dev/null) || return 1
  [[ -z "$target" ]] && return 1
  [[ "$target" = /* ]] || return 1
  # target is <repo>/data/projects (absolute), go up 2 levels
  (cd "$target/../.." 2>/dev/null && pwd) || return 1
}

evolve_git_pull() {
  local repo
  repo=$(evolve_repo_root) || { evolve_log "WARN git-pull: could not resolve repo root"; return 0; }
  local pull_cmd="git -C $repo pull --rebase --autostash"
  if command -v timeout &>/dev/null; then
    pull_cmd="timeout 5 $pull_cmd"
  fi
  if ! $pull_cmd 2>/dev/null; then
    evolve_log "WARN git-pull failed in $repo"
  fi
}

evolve_git_push() {
  local msg="${1:-evolve: sync instincts and proposals}"
  local repo
  repo=$(evolve_repo_root) || { evolve_log "WARN git-push: could not resolve repo root"; return 0; }

  # Serialize git operations with a dedicated lock
  local git_lock="$EVOLVE_DIR/git-sync.lock"
  exec 8>"$git_lock"
  if ! flock -w 10 8; then
    evolve_log "WARN git-push: could not acquire git-sync lock"
    return 0
  fi

  local push_failed=""
  git -C "$repo" add data/projects/ data/global/ 2>/dev/null || push_failed="git add failed"
  if [[ -z "$push_failed" ]] && ! git -C "$repo" diff --cached --quiet -- data/projects/ data/global/ 2>/dev/null; then
    git -C "$repo" commit -m "$msg" -- data/projects/ data/global/ 2>/dev/null || push_failed="git commit failed"
    if [[ -z "$push_failed" ]]; then
      git -C "$repo" push 2>/dev/null || push_failed="git push failed"
    fi
  fi

  # Release lock
  exec 8>&-

  if [[ -n "$push_failed" ]]; then
    evolve_log "WARN git-push: $push_failed in $repo"
  fi
}

# ── Log rotation ────────────────────────────────────────────────────────────
# Truncate evolve.log to the last 1000 lines.

rotate_log() {
  if [[ -f "$EVOLVE_LOG" ]]; then
    local tmp
    tmp="$(mktemp)"
    tail -1000 "$EVOLVE_LOG" > "$tmp"
    mv "$tmp" "$EVOLVE_LOG"
  fi
}
