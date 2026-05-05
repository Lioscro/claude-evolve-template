---
name: promote
description: Run the claude-evolve cross-project promotion process on-demand (bypasses the 1-hour frequency gate).
user_invocable: true
disable-model-invocation: true
---

# /promote -- Run Promotion On-Demand

Trigger the claude-evolve global promotion process immediately, ignoring the
1-hour frequency gate that normally throttles auto-runs from `observe.sh`.

This invokes the promoter agent over all projects' instincts, then either
auto-promotes (when an instinct converges across `auto_promote_threshold`+
projects) or creates a global promotion proposal (when it converges across
`propose_promote_threshold`+ projects). It also applies decay to existing
global instincts that were not reinforced since the last run.

After it runs, use `/evolve` to review any newly created global promotion
proposals.

## Steps

1. Run the promote script with `--force` and surface its output:
   ```bash
   ~/.claude/evolve/scripts/promote.sh --force
   ```

2. Display the script's stdout to the user verbatim. Typical lines:
   - `promote.sh: done (N promoted, N proposed, N decayed, N archived)` -- success
   - `promote.sh: only N project(s) with instincts (need 2+), exiting` -- not enough data yet
   - `promote.sh: global lock held, exiting` -- another evolve write is in flight; retry later
   - `promote.sh: global dir does not exist, exiting` -- global storage not initialized; re-run `install.sh`
   - `promote.sh: evolve disabled, exiting` -- `observer.enabled` is false in `config.yaml`

3. If the summary line reports `N proposed` > 0, suggest the user run `/evolve`
   to review the new promotion proposals.

## Notes

- The script silently no-ops when called inside an evolve agent subprocess
  (`EVOLVE_SUBPROCESS=1`). That should never happen for a user-invoked /promote.
- All writes go through the global lock; the script is safe to invoke
  concurrently with `observe.sh` -- it will exit cleanly if the lock is held.
- This skill does not call `evolve_git_push`. Git sync happens on the next
  `observe.sh` (session start) or via the helper scripts when proposals are
  approved/rejected through `/evolve`.
