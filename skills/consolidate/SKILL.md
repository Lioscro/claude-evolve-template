---
name: consolidate
description: Merge redundant claude-evolve instincts, memories, and pending skill/rule proposals into fewer comprehensive entries for the current project, a specific project, or "all". Reduces injected-context bloat.
user_invocable: true
disable-model-invocation: true
---

# /consolidate -- Merge Redundant Evolve Entries

Analyze a scope's instincts, memories, and pending skill/rule proposals for
redundancy, and merge each redundant group into a single comprehensive entry.
This reduces the number of entries injected into context every session
(memories are injected uncapped and full-body — the biggest win) and cleans up
fragmentation.

Each proposed merge is **staged** and presented for your Approve/Reject before
anything is changed. Merging is destructive (sources are archived), so nothing
is applied without your approval.

Accepts an optional argument `$ARG` (same semantics as `/evolve`):
- empty -> current project (cwd-derived) plus global
- `all` (case-sensitive reserved keyword) -> every managed project plus global
- anything else -> a specific project id (exact match, then case-sensitive substring); project scope only

## Setup

1. Read the argument into `ARG` (may be empty). Determine `MODE`: empty -> `cwd`; literal `all` -> `all`; anything else -> `single`.

2. Resolve project ids. On non-zero exit, stop (the resolver wrote its error to stderr):
   ```bash
   PROJECT_IDS="$(~/.claude/evolve/scripts/select-projects.sh "$ARG")" || exit 1
   ```

3. Determine `INCLUDE_GLOBAL`: `1` for `MODE=cwd` and `MODE=all`; `0` for `MODE=single`.

## Analyze pass

Run the analyzer once per target and surface its stdout verbatim. Each run is a
discrete Bash invocation. Analysis invokes a consolidator agent per entry type,
so it may take a few seconds per target; `all` across many projects runs several
agents.

1. For each `pid` in `PROJECT_IDS` (bash 3.2 safe loop):
   ```bash
   while IFS= read -r pid; do
     [[ -z "$pid" ]] && continue
     ~/.claude/evolve/scripts/consolidate.sh "$pid"
   done <<< "$PROJECT_IDS"
   ```

2. If `INCLUDE_GLOBAL=1`, also analyze global (instincts + memories; global has no skill/rule proposals):
   ```bash
   ~/.claude/evolve/scripts/consolidate.sh --global
   ```

Typical stdout lines: `staged <cid> (<type>): merges N ... -> <name>`, or
`no consolidation candidates for <target>`, or `... lock busy, skipped`.

Re-running analysis for a target discards that target's prior **unapplied**
staged merges and regenerates fresh ones (they are recomputable).

## Present + act pass

For each target (each `pid`, then `global` if included), enumerate its staged
merges by globbing the staging directory and present each:

- Project staging dir: `~/.claude/evolve/consolidations/<pid>/`
- Global staging dir:  `~/.claude/evolve/consolidations/global/`

```bash
for SF in ~/.claude/evolve/consolidations/<target>/*.yaml; do
  [[ -e "$SF" ]] || continue
  # read fields with yq: cid, entry_type, source_ids[], merged_* fields
done
```
If a target's staging dir has no `*.yaml`, it has nothing to review — skip it.

### Presentation

Read the staging file and present, for each staged merge:

- **cid** and **entry_type** (instinct | memory | proposal), and scope.
- **Sources being merged (as they are now)** — read each id in `source_ids` from live storage and show its current form so the user sees what will be archived:
  - `instinct`: read `~/.claude/evolve/projects/<pid>/instincts/<id>.yaml` (or `~/.claude/evolve/global/instincts/<id>.yaml`); show `trigger`, `action`, `confidence`.
  - `memory`: read the entry in the scope's `memory/index.yaml` (title/description) and the body file `memory/<id>.md`.
  - `proposal`: read the source proposal file in `~/.claude/evolve/projects/<pid>/proposals/`; show `type`, `title`, `description`.
- **Merged result** (from the staging file):
  - `instinct`: `merged_name`, `merged_trigger`, `merged_action`, `merged_domain`.
  - `memory`: `merged_name`, `merged_title`, `merged_description`, and the full `merged_content` body.
  - `proposal`: `merged_name`, `merged_type`, `merged_title`, `merged_description`, the full `merged_proposed_content`, and the union `merged_source_instincts`.

Consolidations are approvable from **any** working directory — they only rewrite
data under `~/.claude/evolve/`, never files in a project's checkout.

### Action prompt

Ask the user to choose one of: **Approve**, **Reject**, **Skip** (does nothing, moves on).

### Action execution

Each action is a discrete Bash invocation (git-sync serializes naturally).
Substitute `<target-arg>` with the `pid` for a project target, or `--global`
for the global target.

- **Approve**:
  ```bash
  ~/.claude/evolve/scripts/apply-consolidation.sh <target-arg> <cid>
  ```
  Applies the merge under the lock: re-validates the sources against live state,
  writes the merged entry, archives each source with `archived_reason: consolidated`,
  removes the staging file, and git-pushes. Prints `consolidated N ... into <name>`.
  If it prints `ABORTED: ...` on stderr and exits non-zero, the source pool moved
  since analysis (e.g. an instinct was reinforced past the graduation threshold, a
  proposal was resolved). Re-run the analyze pass for that target and review again.

- **Reject**:
  ```bash
  ~/.claude/evolve/scripts/discard-consolidation.sh <target-arg> <cid>
  ```
  Removes the staging file only. Sources are untouched.

- **Skip**: do nothing; continue to the next staged merge.

## Notes

- A merged **proposal** is itself a new *pending* skill/rule proposal — review and
  approve it with `/evolve` to actually write the artifact. The source proposals are
  archived as `consolidated` (not rejected), so they do not block future re-proposal.
- Proposal consolidation covers **skill/rule proposals in project scope only**.
  Memory proposals (owned by graduation) and promotion proposals (owned by promotion)
  are intentionally excluded.
- Instinct consolidation only touches instincts with confidence in
  `[consolidation.min_confidence, instincts.propose_memory_threshold)` that are not
  already claimed by a pending proposal. Higher-confidence instincts graduate into
  memories, whose redundancy is then handled by *memory* consolidation.
- All writes go through the helper scripts. Do not hand-edit index or staging files.
- `apply-consolidation.sh` and `discard-consolidation.sh` are safe to run
  concurrently with background `observe.sh`; apply waits for the lock, and both
  re-validate live state.
