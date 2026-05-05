---
name: evolve
description: Review and approve/reject pending claude-evolve proposals for the current project, a specific project, or "all".
user_invocable: true
---

# /evolve -- Review Pending Proposals

Review and act on pending proposals from the claude-evolve system. Each proposal suggests a new skill, rule, or memory artifact derived from observed behavioral patterns (project proposals), or the promotion of converging project instincts into a global instinct (global proposals).

Accepts an optional argument `$ARG`:
- empty -> current project (cwd-derived)
- `all` (case-sensitive reserved keyword) -> every managed project plus global proposals
- anything else -> a specific project id (exact match, falling back to case-sensitive substring)

## Setup

1. Read the argument into `ARG` (may be empty).

2. Determine `MODE` from `ARG`:
   - empty -> `cwd`
   - literal `all` (case-sensitive) -> `all`
   - anything else -> `single`

3. Resolve project ids via the resolver. On non-zero exit, stop — the resolver already wrote its error to stderr.
   ```bash
   PROJECT_IDS="$(~/.claude/evolve/scripts/select-projects.sh "$ARG")" || exit 1
   ```

4. Compute the cwd-derived project id:
   ```bash
   CWD_PROJECT_ID="$(~/.claude/evolve/scripts/resolve-project.sh "$(pwd)")"
   ```

5. Determine `SHOW_GLOBAL`:
   - `MODE=cwd` -> `SHOW_GLOBAL=1`
   - `MODE=single` -> `SHOW_GLOBAL=0`
   - `MODE=all` -> `SHOW_GLOBAL=1`

6. In `MODE=all`, check whether `CWD_PROJECT_ID` is among the resolved ids (bash 3.2 safe):
   ```bash
   case $'\n'"$PROJECT_IDS"$'\n' in
     *$'\n'"$CWD_PROJECT_ID"$'\n'*) CWD_IN_RESOLVED=1 ;;
     *) CWD_IN_RESOLVED=0 ;;
   esac
   ```
   If `CWD_IN_RESOLVED=0`, print this notice exactly once:
   ```
   Note: cwd is not a managed evolve project — project-proposal approvals will be unavailable. Reject / Permanently Reject and global approvals still work.
   ```

## Gather pass

Build a flat list `PROPOSALS`. Each entry records:
- `scope` — `project` or `global`
- `project_id` — the project id (empty string for global)
- `proposal_id` — the proposal's `id` field
- `file` — full path to the proposal YAML
- `type` — `skill`, `rule`, `memory`, or `promotion`
- `approvable_here` — boolean; `true` iff `scope=global`, or `scope=project` and `project_id == CWD_PROJECT_ID`

Populate it:

1. For each `project_id` in `PROJECT_IDS` (iterate with a bash 3.2 safe loop):
   ```bash
   while IFS= read -r pid; do
     [[ -z "$pid" ]] && continue
     INDEX="$HOME/.claude/evolve/projects/$pid/proposals/index.yaml"
     [[ -f "$INDEX" ]] || continue
     # iterate .proposals[] from $INDEX via yq; for each entry record:
     #   scope=project, project_id=$pid, proposal_id=<id>,
     #   file=$HOME/.claude/evolve/projects/$pid/proposals/<file>,
     #   type=<read .type from the proposal YAML file>,
     #   approvable_here=( [[ "$pid" == "$CWD_PROJECT_ID" ]] && echo true || echo false )
   done <<< "$PROJECT_IDS"
   ```
   If `yq` fails on a project's index, log via `evolve_log` (sourced from `~/.claude/evolve/scripts/lib.sh`) and silently skip that project. If the index is missing or empty, treat it as zero proposals and skip silently.

2. If `SHOW_GLOBAL=1`, read `~/.claude/evolve/global/proposals/index.yaml` (if it exists) and append one entry per global proposal with `scope=global`, `project_id=""`, `type=promotion`, `approvable_here=true`. Same silent-skip-on-missing / log-on-parse-failure policy.

Order: project entries first, grouped by project in the order they appear in `PROJECT_IDS` (already sorted by the resolver); global entries last.

## Early exit

If `PROPOSALS` is empty, print `No pending proposals.` and stop.

## Present + act pass

For each entry in `PROPOSALS` in order:

### Presentation

Read the full proposal YAML at `file`. Then:

- If `scope=global`, present with a `[GLOBAL]` label and these fields (matching existing global-proposal formatting):
  - **Type**: promotion
  - **Title and description**
  - **Source projects**: list each project contributing to this promotion (from `source_projects`)
  - **Source project instincts**: for each entry in `source_project_instincts`, show the project and instinct id
  - **Proposed trigger**: the synthesized trigger (`proposed_trigger`)
  - **Proposed action**: the synthesized action (`proposed_action`)

- If `scope=project`, present with these fields (matching existing project-proposal formatting):
  - **Type**: skill, rule, or memory
  - **Title and description**
  - **Source instincts**: for each entry in `source_instincts`, show trigger and confidence
  - **Proposed content**: the full artifact text (`proposed_content`)
  - **Destination path**: where the artifact will be written (based on type and name)
  - If `approvable_here=false`, also show the tag: `[readonly here — cd into <project_id> to approve]`

### Action prompt

Ask the user to choose one of:
- **Approve**
- **Reject**
- **Permanently Reject**
- **Edit** (project proposals only — not offered for global)
- **Skip** (always available; does nothing and moves on)

### Action execution

Each action below is a discrete Bash invocation (serializes git-sync naturally).

#### Project proposal with `approvable_here=true`

- **Approve** (or **Edit-then-Approve**): if Edit, let the user modify `proposed_content`. Then in a **single Bash invocation** (do not split across multiple Bash tool calls -- the temp file path will not survive otherwise):
  ```bash
  CONTENT_FILE=$(mktemp -t evolve-content.XXXXXX)
  cat > "$CONTENT_FILE" <<'EVOLVE_PROPOSED_CONTENT_HEREDOC'
  <the proposed_content (or edited version), verbatim, with no shell expansion>
  EVOLVE_PROPOSED_CONTENT_HEREDOC
  PROJECT_ROOT="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || pwd)"
  ~/.claude/evolve/scripts/approve-proposal.sh <project_id> <proposal_id> "$PROJECT_ROOT" "$CONTENT_FILE"
  rm -f "$CONTENT_FILE"
  ```
  The HEREDOC delimiter is single-quoted (`'EVOLVE_PROPOSED_CONTENT_HEREDOC'`) to disable shell expansion of `$`, backticks, and `\` in the proposed content. `approve-proposal.sh` writes the artifact, archives the proposal and source instincts atomically under the project lock, and prints `<type> <name>` on stdout.

- **Reject**:
  ```bash
  ~/.claude/evolve/scripts/reject-proposal.sh <project_id> <proposal_id>
  ```

- **Permanently Reject**:
  ```bash
  ~/.claude/evolve/scripts/reject-proposal.sh <project_id> <proposal_id> --permanent
  ```

- **Skip**: do nothing; continue to the next proposal.

#### Project proposal with `approvable_here=false`

- **Approve** / **Edit**: print this exact message and do not invoke `approve-proposal.sh`:
  ```
  Skipping approve for <proposal_id>: cd into the project root for <project_id> to approve this proposal (writing artifacts requires the project_root).
  ```

- **Reject**:
  ```bash
  ~/.claude/evolve/scripts/reject-proposal.sh <project_id> <proposal_id>
  ```

- **Permanently Reject**:
  ```bash
  ~/.claude/evolve/scripts/reject-proposal.sh <project_id> <proposal_id> --permanent
  ```

- **Skip**: do nothing; continue.

#### Global proposal (always approvable regardless of cwd)

- **Approve**:
  ```bash
  ~/.claude/evolve/scripts/approve-global-proposal.sh <proposal_id>
  ```
  This creates a global instinct and archives the source project instincts.

- **Reject**:
  ```bash
  ~/.claude/evolve/scripts/reject-global-proposal.sh <proposal_id>
  ```
  Source instincts remain active in their projects.

- **Permanently Reject**:
  ```bash
  ~/.claude/evolve/scripts/reject-global-proposal.sh <proposal_id> --permanent
  ```
  Blocks re-proposal of similar instinct groupings via Jaccard overlap check.

- **Edit**: NOT offered for globals.

- **Skip**: do nothing; continue.

## Notes

- All file operations (index updates, archival, file moves, artifact writes) go through the helper scripts. Do not manually edit index files or move proposal/instinct files.
- `approve-proposal.sh` derives the artifact name internally from the proposal's `id` field (strips `proposal-` prefix and trailing `-YYYY-MM-DD` date suffix). The skill no longer needs to compute this.
- `type` is one of: `skill`, `rule`, `memory`.
- If a re-approval of the same proposal hits "ERROR: ... already exists" from `write-artifact.sh`, that's the no-clobber guard (R15). Either delete the orphan artifact and retry, OR retry approve-proposal.sh with the same proposal_id -- the idempotent re-run path (R16) reuses the existing artifact.
- Run all scripts via Bash. They print results to stdout and log errors internally via `evolve_log`.
- Each action is a discrete Bash invocation so `evolve_git_push` pushes serialize naturally through the existing git-sync lock.
