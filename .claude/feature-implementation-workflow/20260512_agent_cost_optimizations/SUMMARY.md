# Agent Cost Optimizations — Implementation Summary

**Plan:** [PLAN.md](PLAN.md)
**Mode:** Sequential subagents (one per phase, in order)
**Started:** 2026-05-12

## Decisions

- **Observer stays on `claude-sonnet-4-6`.** Haiku downgrade rejected after research (false-create / missed-create asymmetry).
- **Reinforcer window default = 50 lines**, configurable via `reinforcement.recent_observations_window`.
- **Promoter pre-filter at `instincts.injection_threshold` (0.5).** Reuses existing config key rather than introducing a new one.
- **`invoke_agent` accepts optional `static_context_file` arg** appended to the system prompt under HTML-comment sentinel `<!-- evolve:runtime-context-begin -->`.
- **Promoter uses `ENABLE_PROMPT_CACHING_1H=1`** to address 5-min TTL vs hourly gate mismatch.
- **Implementation mode: Sequential subagents.** One subagent per phase, each phase fully gates before the next starts.

## Phase progress

### Phase 1: `invoke_agent` static-context refactor

**Status:** ✅ COMPLETE (2026-05-12)

**Files modified:**
- `scripts/lib.sh` — extended `invoke_agent` to accept optional `static_context_file` arg (lines 342-383). Conditional append guarded by `[[ -n "$static_context_file" && -s "$static_context_file" ]]`. Sentinel: `<!-- evolve:runtime-context-begin -->`. Trailing newline after `cat` for robustness.
- `CLAUDE.md` — added `#### invoke_agent static-context argument` subsection (lines 76-110) documenting signature, cache rationale, caller-ownership, graduate.sh asymmetry, and `injection_threshold` dual-subsystem note.

**Gates:**
- Round 1: feature-verifier PASS (16/16 assertions, all bash syntax checks pass). code-reviewer APPROVE WITH SUGGESTIONS — flagged one Important: missing trailing newline after `cat` of static-context.
- Fix applied: added `printf '\n' >> "$tmp_system"` after `cat`.
- Round 2: feature-verifier PASS. code-reviewer APPROVE (Important fix confirmed in place, no new regressions).

**Deviations from plan:** None.

**Suggestions deferred:**
- Reviewer suggestion to drop the inline "what" comment as duplicative of the function header. Kept for in-context readability; minimal cost.
- Reviewer noted the CLAUDE.md forward-reference example for Phase 2 may drift; flagged for Phase 2 reviewer to verify alignment.

### Phase 2: Reinforcer windowing + static-context

**Status:** ✅ COMPLETE (2026-05-12)

**Files modified:**
- `config.yaml` — added `reinforcement.recent_observations_window: 50` under new `reinforcement:` section.
- `scripts/reinforce-worker.sh` — OBS_WINDOW config read placed BEFORE `tail` (line 30, not in the 97-105 block) per C2.A. OBS_WINDOW=0 guard with WARN log (per C2.B Phase 2). `line_count` computed via `printf | grep -c .` (per C2.C). Static-context tempfile contains `## Existing Instincts` + `## Global Instincts`. Stdin contains only `## Recent Observations`. `rm -f "$static_ctx_file"` in both success and failure branches (per C2.D).
- `agents/reinforcer.md` — Input format section updated to note where each section arrives.

**Gates:**
- feature-verifier: PASS. All 12 Phase 2 requirements met. All test script assertions PASS. `bash -n` and `/bin/bash -n` clean. No out-of-scope edits.
- code-reviewer: APPROVE WITH SUGGESTIONS. No Critical or Important issues. The reviewer's "Important"-labeled item was actually a non-issue (reviewer's own analysis concluded "This is actually fine in bash"). Other suggestions: noted byte-stability of static-context (no issue, deterministic loop), flagged pre-existing redundant atomic-write at lines 194-196 (out of scope), noted harmless triple-fallback in OBS_WINDOW read.

**Deviations from plan:** None.

**Suggestions deferred:**
- Pre-existing no-op atomic write at reinforce-worker.sh:194-196 (cp INDEX_FILE to itself) is out of scope.
- Harmless triple-fallback in OBS_WINDOW config read kept for defense-in-depth.

### Phase 3: Observer prefix caching

**Status:** ✅ COMPLETE (2026-05-12)

**Files modified:**
- `scripts/observe.sh` — STATIC_CTX built once before batch loop (line 85). If/else handles empty INSTINCT_YAML case with `(none)` fallback per plan Verification. Combined EXIT trap (`release_lock + rm -f "$STATIC_CTX"`) replaces line-25 trap immediately after STATIC_CTX init (per Changelog C2.B-Phase3). `process_batch` agent_input contains only `## New Observations`. `invoke_agent` passes `"$STATIC_CTX"` as second arg. Explicit `rm -f` on normal path before `trap - EXIT`.
- `agents/observer.md` — Input format section updated.

**Gates:**
- Round 1: feature-verifier PASS. code-reviewer APPROVE WITH SUGGESTIONS — Important issue: missing `(none)` fallback for empty INSTINCT_YAML case (plan Verification explicitly required).
- Fix applied: added if/else block at lines 86-90 for the empty case.
- Test heuristic update: replaced strict ≤5-lines-between-mktemp-and-trap with a stricter functional check (no intervening exit/return statements). The original heuristic became too tight after the (none) fallback added 4 lines but the functional invariant was preserved.
- Round 2: feature-verifier PASS (10/10 assertions, fix confirmed at lines 85-90, combined trap at line 93). code-reviewer APPROVE.

**Deviations from plan:** None.

**Suggestions deferred:** None requiring action.

### Phase 4: Promoter pre-filter + static-context

**Status:** ✅ COMPLETE (2026-05-12)

**Files modified:**
- `scripts/promote.sh` — INJECTION_THRESHOLD config read (lines 67-68). Per-instinct confidence filter using efficient single-yq-call pattern (lines 113-114, per C3.B). PROJECT_COUNT accumulation unchanged per C3.C (zero-instinct-after-filter projects naturally excluded). Static-context tempfile with three sections + `(none)` fallback for EACH section (lines 212-231, including the Project Instincts fallback added in round 2). AGENT_INPUT is minimal trigger. Invoked with `ENABLE_PROMPT_CACHING_1H=1` env var per C3.A. Combined EXIT trap (`release_lock + rm -f static_ctx_file`) at line 210, replacing the line-74 trap. `rm -f` in both success and failure paths. Lock release/reacquire pattern preserved.
- `agents/promoter.md` — Input format section updated.

**Gates:**
- Round 1: feature-verifier PASS. code-reviewer APPROVE WITH SUGGESTIONS — Important issue: `## Project Instincts` section missing `(none)` fallback (other two sections had it; case is currently unreachable but flagged for consistency with plan requirement).
- Fix applied: added if/else `(none)` fallback for `## Project Instincts` matching the other two sections.
- Round 2: feature-verifier PASS. code-reviewer APPROVE.

**Deviations from plan:** None.

**Suggestions deferred:**
- Pre-existing line-74 lock-only trap is superseded (not explicitly cleared) by the combined trap at line 210; bash's last-trap-wins semantics make this correct but mildly confusing to read. Documented in SUMMARY only.

## End-to-End Verification

**Round 1 (2026-05-12):**
- feature-verifier: **PASS**. All 10 plan requirements met. All four /tmp test scripts pass (16+12+10+11=49 assertions). `bash -n` and `/bin/bash -n` clean on all four modified scripts. Tempfile lifecycles audited. `git diff --stat` confirms only expected files touched. No scope creep.
- code-reviewer: **APPROVE WITH SUGGESTIONS**. One Important issue: `reinforce-worker.sh` had no EXIT trap covering `static_ctx_file` in the window between mktemp and the first explicit `rm -f` — inconsistent with the patterns in `observe.sh` (line 89-93) and `promote.sh` (line 208-210). Fix: combined EXIT trap added immediately after mktemp.
- Suggestions: documented `ENABLE_PROMPT_CACHING_1H` rationale in CLAUDE.md. Naming inconsistency (`STATIC_CTX` vs `static_ctx_file`) noted but left as-is (matches each script's local convention).

**Round 2 (2026-05-12):**
- feature-verifier: **PASS**. 49/49 assertions still pass. Combined EXIT trap correctly placed at reinforce-worker.sh:102 immediately after mktemp at line 96. CLAUDE.md update at line 98 is well-placed.
- code-reviewer: **APPROVE**. Pattern now consistent across all three scripts. No regressions.

## Final state

**Files modified (10 total):**
1. `scripts/lib.sh` — `invoke_agent` extended.
2. `scripts/reinforce-worker.sh` — windowing + static-context + combined EXIT trap.
3. `scripts/observe.sh` — STATIC_CTX once outside batch loop + combined EXIT trap.
4. `scripts/promote.sh` — confidence pre-filter + static-context + 1-hour cache + combined EXIT trap.
5. `agents/reinforcer.md` — Input format updated.
6. `agents/observer.md` — Input format updated.
7. `agents/promoter.md` — Input format updated.
8. `config.yaml` — `reinforcement.recent_observations_window: 50`.
9. `CLAUDE.md` — `#### invoke_agent` subsection + `ENABLE_PROMPT_CACHING_1H` note + `injection_threshold` dual-subsystem note.
10. `.claude/feature-implementation-workflow/INDEX.md` — entry added.

**Test artifacts (not committed):**
- `/tmp/test-phase1-invoke-agent.sh` (16 assertions)
- `/tmp/test-phase2-reinforcer.sh` (12 assertions)
- `/tmp/test-phase3-observer.sh` (10 assertions)
- `/tmp/test-phase4-promoter.sh` (11 assertions)

## Open questions / follow-ups

- **Empirical cache-savings measurement** is deferred. The plan's End-to-End Verification step 6 ("Confirm Anthropic prompt-cache utilization improvement via `--output-format json`") was not run as part of the verification gates because the savings are observable through Anthropic billing dashboards in production rather than via unit test. Operators can verify post-deployment by inspecting `cache_creation_input_tokens` / `cache_read_input_tokens` in agent invocations.
- **Pre-existing redundant atomic-write** at `reinforce-worker.sh:194-196` (cp INDEX_FILE to itself) flagged by Phase 2 reviewer; out of scope for this change.
- **Stale `INSTINCT_YAML` across observe.sh batches** is pre-existing behavior (not introduced by this work); the bash-level duplicate-create guard at line 175 handles the worst case.
