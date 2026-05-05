# claude-evolve

A self-evolving behavioral layer for [Claude Code](https://claude.com/claude-code).
It watches how you actually work, distills recurring patterns into "instincts,"
clusters mature instincts into proposals for formal artifacts (skills, rules,
memory), and gates everything behind explicit user approval.

This repository is a **GitHub template**. Click *Use this template* on
[github.com/Lioscro/claude-evolve-template](https://github.com/Lioscro/claude-evolve-template)
to bootstrap your own private copy.

---

## What it does

claude-evolve hooks into Claude Code at the session, prompt, and tool-call
level, and runs a closed feedback loop on top of every session:

1. **Observe.** Each user prompt and tool result is recorded as a JSONL
   observation.
2. **Distill.** A background agent reads the observation log and either
   creates new "instincts" (small behavioral rules with a confidence score
   and a trigger) or reinforces existing ones.
3. **Inject.** Mature instincts (those above a confidence threshold) are
   injected into the next session's context as additional guidance for
   Claude.
4. **Cluster.** Once enough related instincts mature, a clusterer agent
   groups them into a *proposal* — a draft skill, rule, or memory entry.
5. **Approve.** You review pending proposals via the `/evolve` slash command
   and approve, reject, or defer each one. Approved proposals become
   real Claude Code artifacts.
6. **Promote.** Patterns that recur across multiple projects can be
   promoted into *global* instincts that apply everywhere.

Nothing is created without your explicit approval. The system observes and
proposes; you decide.

---

## Why

Claude Code already supports skills, hooks, and a memory system. What it
doesn't have is an automatic way to *notice* the patterns in your own
sessions and turn them into reusable artifacts. You either:

- Manually write skills/memory after the fact (high friction, easy to forget).
- Let recurring corrections drift away as one-off fixes (expensive and
  invisible).

claude-evolve closes that loop. It treats your own session history as the
source of truth for what guidance actually matters, and surfaces
candidate artifacts for you to vet rather than guessing in advance.

---

## Features

- **Per-project and global instincts.** Per-project instincts inject into
  the project they originated in; global instincts inject everywhere.
- **Confidence lifecycle.** Instincts decay over time and are reinforced
  by repeated observed behavior, so stale advice fades naturally.
- **Approval-gated artifact creation.** Skills, rules, and memory entries
  are only created via `/evolve` after you explicitly approve a proposal.
- **Cross-project promotion.** Patterns that recur across two or more
  projects become candidates for global promotion (auto-promoted at three
  matching projects by default).
- **Background workers.** All non-trivial work (observing, reinforcing,
  clustering, promoting) runs out-of-band so it never blocks Claude Code.
- **Single-writer locking.** A flock-based lock per project prevents
  index corruption when multiple sessions run concurrently.
- **Cross-machine sync via git.** All instincts, proposals, and approved
  artifacts live inside this repository, so `git pull` on another machine
  brings your evolved state with you.

---

## How it works (one paragraph)

Hooks in `~/.claude/settings.json` fire `record-observation.sh` on every
prompt and tool result, `reinforce.sh` on session stop, and
`on-session-start.sh` on session start. The session-start hook backgrounds
the observer agent (Sonnet) which reads the latest observation log and
emits create/reinforce/decay decisions. Once enough related instincts pass
a confidence threshold, `cluster.sh` calls the clusterer agent (Sonnet)
which writes a YAML proposal. You review proposals via `/evolve`. Across
projects, the promoter agent (Haiku) finds semantically similar instincts
and proposes them as global instincts. See `CLAUDE.md` for the full
architecture and key invariants.

---

## Prerequisites

- **macOS or Linux.** All shell scripts are bash 3.2 compatible
  (no associative arrays, no bash 4+ features), so the macOS default
  bash works.
- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** —
  the `claude` CLI must be on your `PATH`.
- **[jq](https://jqlang.github.io/jq/)** — JSON processing.
- **[mikefarah/yq v4](https://github.com/mikefarah/yq)** — YAML
  processing. Note: this is the Go version, not the Python `yq` wrapper.
  The installer will refuse to run with the Python version.
- **flock** — used for file locking. On macOS install via
  `brew install flock`. On Linux it is part of `util-linux`.

The installer checks all of these and offers to install `yq` for you.

---

## Getting started

### 1. Create your repository from the template

On GitHub, click **Use this template → Create a new repository** at
[github.com/Lioscro/claude-evolve-template](https://github.com/Lioscro/claude-evolve-template).
In the dialog, set visibility to **Private** — your personal instincts and
proposals will be committed to this repo, so you do not want it public.

### 2. Clone and install

```bash
git clone git@github.com:<you>/<your-repo>.git
cd <your-repo>
./install.sh
```

The installer will:

- Verify prerequisites.
- Create `~/.claude/evolve/` and symlink `agents/`, `scripts/`, `skills/`,
  `config.yaml`, and the `data/` directories from this repo.
- Merge claude-evolve hooks into `~/.claude/settings.json` (idempotent —
  safe to re-run).
- Configure `upstream` to point at the public template repo with its push
  URL locked to `no_push`, so you can pull template updates without ever
  risking publishing your private data.
- Run a one-line agent invocation check.

### 3. Use Claude Code as you normally would

The system runs entirely in the background. After a few sessions you will
start seeing claude-evolve activity reported at session start
(`X project proposal(s), Y global promotion proposal(s) pending`).

### 4. Review proposals

When proposals accumulate, run:

```
/evolve
```

Walk through each proposal and approve, reject, or skip. Approved
proposals create real artifacts (skills under `~/.claude/skills/`, memory
entries under your project's memory dir, etc.).

To inspect system state without acting:

```
/evolve-status
```

To force-run the cross-project promotion analysis (bypasses the 1-hour
frequency gate):

```
/promote
```

---

## Updating from the template

Updates from the public template arrive in your private repo two ways.

### Automated sync (default)

The template ships with `.github/workflows/template-sync.yml`, a GitHub
Actions workflow that runs weekly (Mondays 08:00 UTC) and on manual
dispatch. When the upstream template has new commits, the workflow opens
a pull request against your `main` proposing the diff. Review and merge
the PR like any other.

The workflow is guarded so it no-ops in the template repo itself. It
relies on [AndreasAugustin/actions-template-sync](https://github.com/AndreasAugustin/actions-template-sync),
pinned to a specific commit SHA for supply-chain hygiene.

For the workflow to open PRs, enable two settings under
**Settings → Actions → General** in your repo:

- **Workflow permissions**: *Read and write*.
- **Allow GitHub Actions to create and approve pull requests**: enabled.

To trigger a sync immediately, open the **Actions** tab, select
**Template Sync**, and click **Run workflow**.

To disable auto-sync, delete the workflow file:

```bash
rm .github/workflows/template-sync.yml
git commit -am "Remove template auto-sync"
git push
```

### Manual

You can also pull at any time:

```bash
git pull upstream main
./install.sh
```

The `upstream` remote is configured automatically by `install.sh` on
first run. Re-running `install.sh` after a merge picks up any new hooks,
symlinks, or scripts.

### Push safety

`git push upstream` always fails (push URL is `no_push`) — intentional,
to prevent your private instincts from leaking to the public template.

---

## Repository layout

```
agents/        Agent system prompts (observer, clusterer, reinforcer, promoter)
scripts/       Shell scripts for hooks, agent invocation, lifecycle ops
skills/        User-invocable slash commands (/evolve, /evolve-status, /promote)
data/          Runtime state — your instincts, proposals, observations live here
  projects/    Per-project state, keyed by a stable project id
  global/      Cross-project instincts and promotion proposals
config.yaml    System-wide tuning knobs (thresholds, decay rates, denylists)
install.sh     One-shot installer
uninstall.sh   Removes hooks and (optionally) cleans state
CLAUDE.md      Developer-oriented architecture notes
```

---

## Configuration

Defaults live in `config.yaml` at the repo root. Common knobs:

| Key | Default | What it does |
|---|---|---|
| `instincts.initial_confidence` | `0.3` | Confidence assigned to newly created instincts. |
| `instincts.reinforcement_increment` | `0.15` | Bump when the reinforcer matches an instinct against new behavior. |
| `instincts.injection_threshold` | `0.5` | Minimum confidence for an instinct to be injected into context. |
| `instincts.max_injected` | `10` | Cap on per-project instincts injected per prompt. |
| `instincts.decay_per_run` | `0.05` | Confidence decay applied each observer run. |
| `clustering.min_confidence_for_clustering` | `0.4` | Minimum confidence for an instinct to be eligible for a proposal. |
| `clustering.min_grouping_size` | `2` | Minimum instincts in a cluster before a proposal is generated. |
| `global_instincts.auto_promote_threshold` | `3` | Number of matching projects required for automatic global promotion. |
| `observations.tool_denylist` | `[Read, Glob, Grep, ToolSearch]` | Tool calls excluded from observation logging (low-signal, high-volume). |

Per-project overrides go in `data/projects/<project_id>/config.yaml` and
deep-merge over the global config.

---

## Data and privacy

- **Everything runs locally.** The agents are invoked through your local
  `claude` CLI; no claude-evolve infrastructure exists outside your
  machine and your private repo.
- **Your instincts and proposals are committed to this repo.** That is by
  design — `git push origin` is how you sync your evolved state across
  machines. This is the reason the template-derived repo must be private.
- **Lock files and observation logs are not committed.** The `.gitignore`
  excludes `data/projects/*/observations/`, lock files, and lock
  directories. Observations are archived locally after each observer run.
- **The public template never receives your data.** `install.sh` locks
  `upstream`'s push URL to `no_push`. Even if you mistype `git push
  upstream`, the push fails immediately.

---

## Status and limitations

- **Tested primarily on macOS** with the system bash 3.2 and Anthropic's
  `claude` CLI. Linux should work; bash compatibility has been a hard
  constraint throughout.
- **The proposal pipeline is non-deterministic.** Different sessions may
  generate slightly different clusters from the same instincts. Approval
  is the source of truth.
- **Confidence values are heuristics**, not calibrated probabilities. Tune
  thresholds in `config.yaml` if proposals fire too eagerly or too
  rarely.
- **Hooks must never block Claude.** If you modify `scripts/`, preserve
  the `evolve_trap` / `exit 0` discipline and background long work.

---

## Uninstall

```bash
./uninstall.sh
```

Removes hooks from `~/.claude/settings.json`, removes the `~/.claude/evolve/`
symlinks, and asks before deleting your accumulated state.

---

## License

[MIT](LICENSE).
