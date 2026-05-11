# PR #2 review fixes (round 2) — Implementation Summary

**Created:** 2026-05-08
**Plan:** `PLAN.md` (revision 1)
**Mode:** Direct implementation

## Phase status

| Phase | Status | Notes |
|-------|--------|-------|
| Phase 1: graduate.sh fixes | COMPLETE | Applied as direct implementation alongside Phase 2. |
| Phase 2: Documentation | COMPLETE | Same. |
| Per-phase gates | PASS | feature-verifier: PASS (all 8 reqs satisfied). code-reviewer: APPROVE (one Suggestion-level item applied: removed workflow-scoped PLAN.md cross-reference from inline comment). |

## Decisions and deviations during implementation

- **Phase 1 + Phase 2 merged into a single direct implementation.** Per user choice in Step 4. The two phases are independent (touch disjoint files) so this is safe.
- **Hoisted resume_orphans precheck instead of per-iteration.** Plan revision-1 chose hoisting because `approve_script` is a constant within the function. Saves N-1 stat calls per resume invocation. Skip semantics: `release_lock; trap - EXIT; return 0` (matches the existing lock-acquisition-failure path on line 196).
- **Main-flow precheck is per-iteration, not hoisted.** Only the auto-tier branch within the FILTERED_BUFFER loop calls `approve_script`; not every iteration enters that branch. Per-iteration is cleaner than tracking "is there at least one auto-tier candidate".
- **Collision guard uses `[[ -f ]]` not `[[ -e ]]`.** Plan revision-1 changed this for consistency with surrounding code (`graduate.sh` uses `-f` checks for proposal-file existence throughout).

## Reviewer suggestions: accepted / deferred

- **Accepted (code-reviewer)**: removed the `# See PLAN.md "Preempt-then-skip note"` cross-reference from the inline collision-guard comment in `graduate.sh`. PLAN.md is workflow-scoped and would age poorly as a target for an inline source-code reference. The remaining inline comment is self-explanatory.
- **Accepted (feature-verifier non-critical 1)**: the R5 description in PLAN.md mentions `proposals/archived/` in addition to `memory/` for `approve-global-proposal.sh`'s init_global rationale, but the Step 1 template (which the implementation followed) lists only `memory/`. Both are factually accurate; the implementation's wording is a strict subset of the requirement description. No change applied — the comment is concise and accurate.
- **Accepted (feature-verifier non-critical 2)**: implementation says "self-heals the live and archived indexes" (more precise than the plan template's "self-heals the indexes"). Strict improvement; kept as-is.

## Open questions and follow-ups (post-merge)

These are non-blocking observations surfaced during review that are intentionally deferred:

1. **Pre-existing TEMP_PCS sweep gap** (graduate.sh ~lines 994-1001). On the lock-lost-during-auto-dispatch break path, un-iterated FILTERED_BUFFER entries leave their proposed_content tempfiles orphaned in `/tmp/`. The post-loop comment block ("We've already rm'd surviving paths") implies all entries are handled but doesn't acknowledge this narrow path. Pre-existing, not introduced or worsened by round-2 fixes. Future cleanup could either add a post-loop sweep over TEMP_PCS or revise the comment to be accurate. Scope-correct to leave alone for this round.
2. **R5 documentation symmetry**: the lib.sh init_global comment lists `approve-global-proposal.sh`'s rationale as "ensures `$GLOBAL_DIR/memory/` exists." The script also writes to `$GLOBAL_DIR/proposals/archived/` during memory-proposal archival. The comment is a strict subset of what init_global provides; could be expanded to mention `proposals/archived/` for completeness. Cosmetic.

## End-to-end verification summary

Both end-to-end gates passed cleanly:

- **feature-verifier (sonnet, E2E)**: **PASS** — All 8 plan requirements satisfied; cross-cutting integration scenarios sound (collision guard + preempt block, lock invariants, crash-recovery, documentation coherence). Three /tmp tests (`test_collision_guard.sh`, `test_exec_precheck.sh`, `test_field_order.sh`) all PASS. `bash -n` and `/bin/bash -n` both clean. No Critical or Non-Critical findings.
- **code-reviewer (sonnet, E2E)**: **APPROVE** — All requirements satisfied; concurrency/locking analysis confirms no fd-9 leak or double-release possible across new control-flow paths; bash 3.2 / yq v4 / hook-script invariants preserved; no security regressions. One pre-existing TEMP_PCS sweep observation (above, deferred).

Final files inventory:

- **Modified**: `scripts/graduate.sh` (~37 net lines added: collision guard +9, main-flow precheck +10, hoisted resume_orphans precheck +10, plus heredoc field-order alignment and printf swap).
- **Modified**: `scripts/lib.sh` (~8 net lines added: expanded init_global comment block).
- **Modified**: `CLAUDE.md` (~2 net lines added: behavioral note paragraph in archive_proposal section).
- **New**: `.claude/feature-implementation-workflow/20260508_pr2_review_fixes_round2/PLAN.md`.
- **New**: `.claude/feature-implementation-workflow/20260508_pr2_review_fixes_round2/SUMMARY.md`.
