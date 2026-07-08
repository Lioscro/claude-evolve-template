---
name: compress
description: Rewrite verbose claude-evolve instincts and memories to terse text in place (1-to-1, meaning-preserving) for the current project, a specific project, or "all". Reduces per-session injected-context volume.
user_invocable: true
disable-model-invocation: true
---

# /compress -- Shorten Evolve Entries In Place

Rewrite a scope's instinct `trigger`/`action` text and memory bodies to be terse
without changing their meaning, identity, confidence, or count. This shrinks the
text injected into context every session (memories are injected uncapped and
full-body -- the biggest win). It is a 1-to-1 rewrite: nothing is merged, renamed,
archived, or dropped (use `/consolidate` to merge redundant entries).

Each proposed rewrite is **staged** and presented for your Approve/Reject before
anything is changed. Rewriting changes wording, so nothing is applied without your
approval.

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
discrete Bash invocation. Analysis invokes a compressor agent per entry type, so
it may take a few seconds per target.

1. For each `pid` in `PROJECT_IDS` (bash 3.2 safe loop):
   ```bash
   while IFS= read -r pid; do
     [[ -z "$pid" ]] && continue
     ~/.claude/evolve/scripts/compress.sh "$pid"
   done <<< "$PROJECT_IDS"
   ```

2. If `INCLUDE_GLOBAL=1`, also analyze global:
   ```bash
   ~/.claude/evolve/scripts/compress.sh --global
   ```

Typical stdout lines: `staged <cid> (<type>): <id>`, or `no compression candidates
for <target>`, or `... lock busy, skipped`.

Re-running analysis for a target discards that target's prior **unapplied** staged
rewrites and regenerates fresh ones (they are recomputable).

## Present + act pass

For each target (each `pid`, then `global` if included), enumerate its staged
rewrites by globbing the staging directory and present each:

- Project staging dir: `~/.claude/evolve/compressions/<pid>/`
- Global staging dir:  `~/.claude/evolve/compressions/global/`

```bash
for SF in ~/.claude/evolve/compressions/<target>/*.yaml; do
  [[ -e "$SF" ]] || continue
  # read fields with yq: cid, entry_type, source_id, compressed_* fields
done
```
If a target's staging dir has no `*.yaml`, it has nothing to review -- skip it.

### Presentation

Read each staging file and present, for each staged rewrite (there may be many;
present them together as a compact before/after list):

- **cid**, **entry_type** (instinct | memory), and scope.
- **source_id** -- the entry being rewritten (its id does not change).
- **Before** -- read the live entry:
  - `instinct`: `~/.claude/evolve/projects/<pid>/instincts/<source_id>.yaml` (or `~/.claude/evolve/global/instincts/<source_id>.yaml`); show `trigger` and `action`.
  - `memory`: the body file `memory/<file>.md` (the `file` field of the `source_id` entry in the scope's `memory/index.yaml`).
- **After** (from the staging file):
  - `instinct`: `compressed_trigger`, `compressed_action`.
  - `memory`: `compressed_title`, `compressed_description`, and the full `compressed_content` body.

Compressions are approvable from **any** working directory -- they only rewrite
data under `~/.claude/evolve/`, never files in a project's checkout.

### Action prompt

Ask the user to choose per rewrite (bulk answers like "approve all" are fine):
**Approve**, **Reject**, **Skip** (does nothing, moves on).

### Action execution

Each action is a discrete Bash invocation. Substitute `<target-arg>` with the
`pid` for a project target, or `--global` for the global target.

- **Approve**:
  ```bash
  ~/.claude/evolve/scripts/apply-compression.sh <target-arg> <cid>
  ```
  Applies the rewrite under the lock: re-validates the live entry, rewrites its
  text in place, removes the staging file, and git-pushes. Prints
  `compressed <type> <id>`. If it prints `ABORTED: ...` on stderr and exits
  non-zero, the entry changed since analysis (a concurrent reinforce/edit).
  Re-run the analyze pass for that target and review again.

- **Reject**:
  ```bash
  ~/.claude/evolve/scripts/discard-compression.sh <target-arg> <cid>
  ```
  Removes the staging file only. The entry is untouched.

- **Skip**: do nothing; continue to the next staged rewrite.

## Notes

- Compression NEVER merges, renames, archives, or drops entries, and never changes
  confidence or provenance -- only `trigger`/`action` (instinct) or body +
  title/description (memory). To merge redundant entries, use `/consolidate`.
- Entries already terser than the configured thresholds
  (`compression.min_instinct_chars`, `compression.min_memory_chars`) are skipped,
  as are entries the agent judges already compact.
- All writes go through the helper scripts. Do not hand-edit index or staging files.
- `apply-compression.sh` is safe to run concurrently with background `observe.sh`
  / reinforcement; it waits for the lock and re-validates live state, aborting
  rather than clobbering a concurrent change.
