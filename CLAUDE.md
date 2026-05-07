# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

claude-evolve is a self-evolving system for Claude Code. It observes user sessions via Claude Code hooks, distills behavioral patterns into "instincts," clusters mature instincts into proposals for formal artifacts (skills, rules, memory), and gates artifact creation behind explicit user approval via `/evolve`.

All runtime state lives in `~/.claude/evolve/` (symlinked from this repo by `install.sh`). Per-project data lives under `~/.claude/evolve/projects/{project_id}/`.

## Install / Uninstall

```bash
./install.sh    # symlinks into ~/.claude/evolve/, merges hooks into settings.json
./uninstall.sh  # removes hooks and optionally cleans project data
```

Prerequisites: `jq`, `yq` (mikefarah/yq v4), `flock`, `claude` CLI. On macOS install `flock` via `brew install flock`.

## Shell Constraints

All scripts must run on macOS default bash (3.2). This means:
- No associative arrays (`declare -A`)
- No `${!array[@]}` for indirect expansion
- No bash 4+ features

## yq Usage

This project uses **mikefarah/yq v4** (Go version), not the Python `yq` wrapper. Key differences:
- No `-r` or `-y` flags (those are Python yq / jq flags)
- No `map(select(...))` -- use `[.[] | select(...)]` instead
- Multi-file merge: `yq ea "select(fi == 0) * select(fi == 1)" file1 file2`
- `//` is the alternative operator (like jq): `.field // "default"`

## Architecture

### Hook Flow

```
UserPromptSubmit  ->  record-observation.sh (appends JSONL)
PostToolUse       ->  record-observation.sh (appends JSONL, respects tool denylist)
SessionStart      ->  matcher="startup":
                        on-session-start.sh:
                          1. check-proposals.sh (sync, prints notification)
                          2. observe.sh (backgrounded via nohup)
                             -> observer agent -> create/reinforce instincts
                             -> cluster.sh -> clusterer agent -> create proposals
                             -> promote.sh -> promoter agent -> promote instincts globally
                             -> graduate.sh -> memory-writer agent -> create memory proposals
                                              (or auto-approve above auto_memory_threshold)
                  ->  no matcher (fires on startup/resume/compact):
                        inject-instincts.sh (stdout = additionalContext)
                        inject-memories.sh  (stdout = additionalContext)
Stop              ->  reinforce.sh (backgrounds reinforce-worker.sh)
                        -> reinforcer agent -> bump instinct confidence
```

### Key Invariants

- **Hook scripts must never block Claude.** All scripts trap ERR via `evolve_trap` and exit 0. Long work (observe, reinforce, cluster) is backgrounded.
- **Recursive hook prevention.** All hook entrypoints check `EVOLVE_SUBPROCESS=1` env var and exit early. `invoke_agent` sets this when calling `claude -p`.
- **Single writer lock.** `evolve.lock` (per-project) serializes writes to instinct/proposal indexes. `observe.sh` holds the lock during analysis, releases it before calling `cluster.sh`. `approve-proposal.sh` requires the lock (exits with error if held).
- **Atomic index writes.** All index.yaml updates write to a temp file then `mv` to the target path.

### Data Model

- **Observations**: JSONL files per session in `observations/`, archived after processing
- **Instincts**: Individual YAML files in `instincts/`, tracked by `instincts/index.yaml`. Confidence floats between 0-1, decayed each observer run, bumped by reinforcement.
- **Proposals**: Individual YAML files in `proposals/`, tracked by `proposals/index.yaml`. Created by clusterer when enough related instincts reach `min_confidence_for_clustering`.
- **Memories**: Individual markdown files in `memory/`, tracked by `memory/index.yaml`. Created when a `type=memory` proposal is approved (`approve-proposal.sh` writes the artifact and appends to the index under the project lock). Project memories live at `data/projects/{project_id}/memory/{name}.md`; global memories live at `data/global/memory/global-{name}.md` (written by `approve-global-proposal.sh` for global-scope proposals). Injected verbatim under `[claude-evolve] Active memories ...` headers on every `SessionStart` (startup, resume, compact); ALL memories are injected — no decay, no top-N filter. `approve-proposal.sh` accepts empty `PROJECT_ROOT` when `type=memory` (the artifact destination is under `$EVOLVE_DIR`, not the project root).

### Agent Definitions

Agent `.md` files in `agents/` have YAML frontmatter (model, description) followed by the system prompt. `invoke_agent` in `lib.sh` strips frontmatter, extracts the model, writes the body to a temp file, and calls `claude -p --system-prompt-file`.

### Confidence Lifecycle

Defaults below; see `config.yaml` for current values (the parenthetical numbers reflect the committed defaults at the time of writing — keep `config.yaml` as the source of truth).

1. Created at `initial_confidence` (0.5)
2. Reinforced by `reinforcement_increment` (0.05) when the reinforcer agent matches session behavior. Capped at `max_confidence` (1).
3. Decayed by `decay_per_run` (0.02) each observer run (floor: `decay_floor` 0)
4. Injected into context when >= `injection_threshold` (0.5)
5. Eligible for clustering when >= `min_confidence_for_clustering` (0.4)
6. Archived when a proposal containing them is approved
7. Eligible for memory graduation when >= `propose_memory_threshold` (0.85, project) or >= `global_instincts.propose_memory_threshold` (0.85, global) — `graduate.sh` proposes a memory artifact; above `auto_memory_threshold` (0.95) it auto-approves.

Global instincts have their own copies of `initial_confidence`, `reinforcement_increment`, `max_confidence`, `injection_threshold`, `decay_per_run`, `decay_floor`, `propose_memory_threshold`, and `auto_memory_threshold` under `global_instincts:` — they are tuned independently of project instincts.

### Rejection Overlap

`cluster.sh` computes Jaccard similarity (intersection/union of instinct ID sets) between new groupings and archived proposals. Permanently rejected proposals always block re-proposal above the overlap threshold. Regular rejected proposals block only if the new grouping doesn't exceed the rejected proposal's source count (allows strictly larger groupings to re-propose).

### Memory Graduation

`graduate.sh` runs after `promote.sh` in the `observe.sh` flow. It scans project and global instincts independently, identifying candidates above the memory graduation thresholds, and produces `type=memory` proposals (or auto-approves them).

**Thresholds** (see `config.yaml` for current values):
- `instincts.propose_memory_threshold` (default 0.85): instincts at or above this confidence are passed to the `memory-writer` agent, which produces a pending memory proposal requiring `/evolve` approval.
- `instincts.auto_memory_threshold` (default 0.95): instincts at or above this confidence are auto-approved — the proposal is created and immediately passed to `approve-proposal.sh` without user action.
- Global equivalents live under `global_instincts.propose_memory_threshold` and `global_instincts.auto_memory_threshold`.
- `auto_memory_threshold >= propose_memory_threshold` is enforced; a violation logs WARN and skips the affected scope, writing `$PROJECT_DIR/.graduation-warning` (or `$GLOBAL_DIR/.graduation-warning`). `check-proposals.sh` surfaces these files as notification lines.

**Per-run cap**: `graduation.max_per_run_per_scope` (default 10) bounds how many memory proposals graduate.sh creates in a single run. Subsequent runs drain the remaining candidates.

**Agent model**: `graduation.agent_model` (default `claude-haiku-4-5-20251001`) controls the model used for the `memory-writer` agent. Can be overridden per-call via `EVOLVE_AGENT_MODEL_OVERRIDE`.

**Frequency**: graduate.sh runs every `observe.sh` tick with no frequency gate (unlike `promote.sh`'s 1-hour gate). Each run is cheap when no candidates exist — the candidate-filter loop is O(N) yq iterations with no LLM calls if nothing passes the threshold.

**Placement in observe.sh**: graduate.sh runs after promote.sh (so it sees post-decay, post-promotion confidence values) and before the final `evolve_git_push`.

#### Memory graduation rejection-overlap policy

Unlike the Jaccard-based overlap check for clusterer proposals, graduate.sh uses strict single-instinct matching:

- Only a memory proposal with `source_instinct_count == 1` and `source_instincts[0] == <instinct_id>` blocks re-graduation for that instinct.
- Multi-instinct rejected proposals (from the old clusterer, before Phase 3) do NOT block single-instinct memory proposals for any subset.
- Persistence: both `rejected` and `permanently_rejected` statuses permanently block re-graduation. `superseded_by_auto` does NOT block (the superseded proposal was replaced by auto-approval, not vetoed).
- Manual unblock: edit the archived proposals index to remove or change the entry's status, then run `unskip-instinct.sh` if a skip-state sidecar entry also exists.

### `lib.sh` Helpers

#### `archive_proposal()`

Moves a pending proposal to its archived directory, rewrites both the live and archived indexes atomically, and returns 0 on success.

Signature:
```
archive_proposal <proposal_file_path> <archive_dir> <archived_index_path> <live_index_path> <new_status>
```

Called from `reject-proposal.sh` and `graduate.sh` (for `superseded_by_auto` archival). The caller must hold the appropriate lock (`evolve.lock` for project, `global.lock` for global). The helper is idempotent: if the source file is already at the archive path (crash-recovery scenario), it skips the move and repairs the indexes.

#### `acquire_lock_blocking()`

Blocking variant of `acquire_lock` for admin scripts that must wait for the lock rather than skip.

Signature:
```
acquire_lock_blocking <lock_file> [timeout_seconds]
```

Default timeout is 30 seconds. Uses fd 9, same slot as `acquire_lock`; `release_lock` works for both. Used by `unskip-instinct.sh`.

#### `invoke_agent` model override

`invoke_agent` checks `EVOLVE_AGENT_MODEL_OVERRIDE` before reading the agent file's frontmatter model. Set this env var for a per-call model override without modifying agent files:

```bash
EVOLVE_AGENT_MODEL_OVERRIDE="claude-sonnet-4-5" invoke_agent agents/memory-writer.md ...
```

Unset callers fall back to the model in the agent's frontmatter.

### Admin Commands

#### `unskip-instinct.sh`

Clears a skip-state entry from the `.graduate-state.yaml` sidecar for a specific instinct, allowing graduate.sh to re-attempt memory proposal on the next run.

Usage:
```
unskip-instinct.sh PROJECT_ID INSTINCT_ID [--global]
```

Pass `--global` for global-scope instincts. Uses `acquire_lock_blocking` and exits non-zero on failure (does NOT use `evolve_trap`; failures surface as errors).

### Config Keys (new in memory graduation)

The following keys were added to `config.yaml` for the memory graduation feature:

| Key | Default | Description |
|-----|---------|-------------|
| `instincts.propose_memory_threshold` | 0.85 | Confidence at which a project instinct becomes a pending memory proposal |
| `instincts.auto_memory_threshold` | 0.95 | Confidence at which a project instinct is auto-approved as a memory |
| `global_instincts.propose_memory_threshold` | 0.85 | Same, for global instincts |
| `global_instincts.auto_memory_threshold` | 0.95 | Same, for global instincts |
| `graduation.max_per_run_per_scope` | 10 | Maximum new memory proposals per graduate.sh run per scope |
| `graduation.agent_model` | `claude-haiku-4-5-20251001` | Model used by the memory-writer agent |

### `write-artifact.sh` scope flag

`write-artifact.sh` accepts an optional `--scope global` flag as its first argument. When present, the artifact is written to `$GLOBAL_DIR/memory/global-{name}.md` — the `global-` prefix is always added by `write-artifact.sh`; callers pass the bare name. Currently only `type=memory` is supported for `--scope global`.
