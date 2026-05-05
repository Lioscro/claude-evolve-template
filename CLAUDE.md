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
UserPromptSubmit  ->  inject-instincts.sh (stdout = additionalContext)
                  ->  record-observation.sh (appends JSONL)
PostToolUse       ->  record-observation.sh (appends JSONL, respects tool denylist)
SessionStart      ->  on-session-start.sh:
                        1. check-proposals.sh (sync, prints notification)
                        2. observe.sh (backgrounded via nohup)
                           -> observer agent -> create/reinforce instincts
                           -> cluster.sh -> clusterer agent -> create proposals
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

### Agent Definitions

Agent `.md` files in `agents/` have YAML frontmatter (model, description) followed by the system prompt. `invoke_agent` in `lib.sh` strips frontmatter, extracts the model, writes the body to a temp file, and calls `claude -p --system-prompt-file`.

### Confidence Lifecycle

1. Created at `initial_confidence` (0.3)
2. Reinforced by `reinforcement_increment` (0.15) when the reinforcer agent matches session behavior
3. Decayed by `decay_per_run` (0.05) each observer run (floor: `decay_floor` 0.1)
4. Injected into context when >= `injection_threshold` (0.5)
5. Eligible for clustering when >= `min_confidence_for_clustering` (0.4)
6. Archived when a proposal containing them is approved

### Rejection Overlap

`cluster.sh` computes Jaccard similarity (intersection/union of instinct ID sets) between new groupings and archived proposals. Permanently rejected proposals always block re-proposal above the overlap threshold. Regular rejected proposals block only if the new grouping doesn't exceed the rejected proposal's source count (allows strictly larger groupings to re-propose).
