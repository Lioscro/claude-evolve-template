# Repo-resident memory storage — Implementation Summary

**Plan:** [PLAN.md](PLAN.md)
**Approved:** 2026-05-06
**Implementation mode:** Sequential subagents
**Phase order:** P1 → P2 → P3 → P4 → P5

---

## Phase progress

### Phase 1: Foundation
- Status: COMPLETE (re-implemented after P2 implementer accidentally reverted)
- Implementer: sonnet (general-purpose) — first pass; then re-applied directly via Edit after P2 implementer's git operations reverted the P1 changes
- Verifier: sonnet (feature-verifier) — first pass PASS WITH WARNINGS; re-verified post-redo via `/tmp/test_p1_redo.sh` 14/14 PASS
- Reviewer: sonnet (code-reviewer) — PASS (suggestions only)
- Files modified: `scripts/lib.sh`
- Smoke test: `/tmp/test_p1_redo.sh` — 14/14 PASS (idempotency, regression, schema correctness, no `last_promote_run` on global memory index)
- Notes: P1 changes were reverted by the P2 implementer during their cleanup of test pollution (they reset lib.sh thinking it was test state). The user's commit `ebc2f4a config: align global_instincts schema...` (config.yaml only) was made during this session by the P2 implementer/user pair. P1 was re-applied directly via Edit and re-verified end-to-end with P2.
- Reviewer's pre-existing-gap finding on `validate_id` for `init_project($1)` is inherited and out of scope for this PR.

### Tuning changes co-submitted in this PR (unrelated to memory storage but intentional)
- `instincts.initial_confidence`: 0.3 → 0.6
- `instincts.reinforcement_increment`: 0.15 → 0.05
- `instincts.max_confidence`: 0.95 → 1
- `instincts.injection_threshold`: 0.5 → 0.6
- `instincts.decay_per_run`: 0.05 → 0.02
- `instincts.decay_floor`: 0.1 → 0
- `global_instincts.decay_per_run`: 0.03 → 0.02
- `global_instincts.decay_floor`: 0.1 → 0
- `global_instincts.max_injected`: 5 → 10

### Phase 2: Redirect writes
- Status: COMPLETE
- Implementer: sonnet (general-purpose) — reported success, scope drift noted
- Verifier: sonnet (feature-verifier) — initially flagged P1-missing as Critical (caused by P2 implementer's revert); after P1 was re-applied, re-tested end-to-end via `/tmp/test_p1p2_iso.sh` 9/9 PASS
- Reviewer: sonnet (code-reviewer) — PASS with one Important finding (`validate_id` on `PROPOSAL_ID` — flagged as pre-existing gap, out of scope for this PR; noted for follow-up)
- Files modified (in scope): `scripts/write-artifact.sh`, `scripts/approve-proposal.sh`
- Files modified (out of scope, user-confirmed intentional): `scripts/inject-instincts.sh`, `scripts/reinforce-worker.sh`, `config.yaml` (added per-global tuning keys: `global_instincts.injection_threshold`, `reinforcement_increment`, `max_confidence`; changed `instincts.initial_confidence` to 0.5)
- Smoke tests: implementer's 25/25 PASS + my own 9/9 PASS end-to-end with HOME-isolated EVOLVE_DIR (verified file written at new path, content matches, index entry uses PROPOSAL_ID as id, no `type` field, no MEMORY.md, no legacy path file, recovery R16 idempotent)
- Incidents:
  - P2 implementer's earlier test iterations leaked test data to the live `claude-evolve` repo's pushed remote — 3 evolve(approve) test commits with 2 reverts + 1 cleanup commit. User confirmed leave-as-is.
  - During cleanup, P2 implementer reverted P1's lib.sh changes. Re-applied directly.
  - My own (Claude) initial integration test also leaked to the live evolve repo (lib.sh's hardcoded `$HOME/.claude/evolve` overrides any `EVOLVE_DIR` export). Cleaned up `/Users/joseph.min/git/claude-evolve/data/projects/test_proj/` and re-tested with full HOME override.
- Follow-up suggestions (not applied; out of scope): add `validate_id "$PROPOSAL_ID"` at line 16 of approve-proposal.sh (pre-existing gap newly motivated by Step 5b yq interpolation).

### Phase 3: Injection script
- Status: COMPLETE
- Implementer: direct (Claude main thread, post-P2 incidents) — chose direct implementation over subagent to avoid scope drift recurrence
- Verifier: sonnet (feature-verifier) — PASS, 25/25 plan checklist items + 6 integration test cases
- Reviewer: sonnet (code-reviewer) — PASS (no Critical/Important; one Suggestion noting better-than-plan variable names)
- Files added: `scripts/inject-memories.sh` (mode 0755)
- Smoke test: `/tmp/test_p3_inject.sh` — 13/13 PASS (empty case, project-only, project+global, missing-file warning, EVOLVE_SUBPROCESS=1 silent, malformed YAML graceful)
- Notes: Implementation follows inject-instincts.sh idioms exactly. Single tab-separated yq extraction + `while IFS=$'\t' read` loop. `[[ -f $MEM_PATH ]]` guard skips missing files with `evolve_log` warning. Output uses `=== <id> ===` delimiter before each entry. Reviewer noted this is a strict improvement on the plan's pseudocode (uses `PROJECT_INDEX`/`PROJECT_MEM_DIR` instead of generic `INDEX_FILE`/`MEM_DIR`).

### Phase 4: Hook registration
- Status: COMPLETE
- Implementer: direct (Claude main thread) — same risk-management as P3
- Verifier: deferred — covered by `/tmp/test_p4_hooks.sh` (14/14 PASS) which exercises the merge filter, idempotency, migration scenario, uninstall preservation of user-custom commands, and partial-install detector update
- Reviewer: deferred — implementation matches plan's pseudocode line-for-line; merge filter unchanged
- Files modified: `install.sh` (added `inject-memories.sh` to SessionStart no-matcher row + updated partial-install detector expected list)
- uninstall.sh: no change required (regex `contains("evolve/scripts/")` handles new script automatically — verified by sub-test D)

### Phase 5: Documentation
- Status: COMPLETE
- Implementer: direct (Claude main thread)
- Verifier: deferred to Step 6 end-to-end
- Reviewer: deferred to Step 6 end-to-end
- Files modified: `CLAUDE.md`, `README.md`, `skills/evolve/SKILL.md`, `agents/clusterer.md`
- Notes:
  - CLAUDE.md: Hook Flow rewritten to match install.sh's actual wiring (inject-instincts.sh and inject-memories.sh both on SessionStart no-matcher, fixing the pre-existing UserPromptSubmit staleness). New Memories bullet added under Data Model with full storage, injection, and no-decay/no-top-N description.
  - README.md: step 3 of "What it does" now mentions memory injection at every session start. Step 4 "Review proposals" now spells out the new memory destination at `data/projects/{project_id}/memory/{name}.md` and explicitly disambiguates from Claude-native auto-memory at `~/.claude/projects/{cwd}/memory/`.
  - skills/evolve/SKILL.md: Destination path bullet expanded to enumerate the path for each artifact type, including the new memory path.
  - agents/clusterer.md: Output schema example and MEMORY artifact-type guideline updated to drop the YAML frontmatter requirement (redundant with index.yaml; would inject verbatim noise on every session start). Added explicit guidance that memory `proposed_content` is plain markdown body and must be self-contained.

---

## Decisions made during implementation

(populated as work proceeds)

## Deviations from the plan

(populated as work proceeds)

## Reviewer suggestions accepted/deferred

(populated as work proceeds)

## End-to-end verification

Run via two parallel gates (sonnet feature-verifier + sonnet code-reviewer) plus a final integration test (`/tmp/test_final_e2e2.sh` 8/8 PASS).

**Feature-verifier verdict: PASS.** All 14 plan requirements implemented and verified. All syntax checks pass under both `bash` (5.x) and `/bin/bash` (3.2). Per-phase reverification (P1 init structure, P2 approve flow, P3 inject flow, P4 hook merge filter, P5 doc accuracy) all PASS. Cross-cutting integration (init → approve → inject pipeline) PASS. Git status shows the expected file set and nothing unexpected.

**Code-reviewer verdict: PASS** with one Important finding and two Suggestions, all applied:
- (Important, applied) Add `validate_id "$PROPOSAL_ID"` after line 16 of `approve-proposal.sh`. Closes a pre-existing yq-injection gap newly relevant given Step 5b's new yq interpolation sites.
- (Suggestion, applied) `CLAUDE.md` Confidence Lifecycle section was showing pre-tuning values; updated to current `config.yaml` defaults (0.5/0.05/1/0.5/0.02/0) and added a note that `config.yaml` is the source of truth, plus mention of the new global_instincts tuning split.
- (Suggestion, applied) Removed stray double blank line in `write-artifact.sh` between the `cp` and `evolve_log` lines.

**Cleanup:** Removed orphan test-pollution artifact at `/Users/joseph.min/.claude/projects/var-folders-th-...-proj_root/` (residue from the P2 implementer's earlier non-isolated test run). No more `evolve-*.md` files anywhere on disk under `~/.claude/projects/`.

**Final integration test (`/tmp/test_final_e2e2.sh`) — 8/8 PASS:**
1. PROPOSAL_ID `validate_id` rejects malformed input
2. Memory file at new repo path
3. Content matches CONTENT_FILE byte-for-byte
4. Inject: project header present
5. Inject: `=== <PROPOSAL_ID> ===` delimiter present
6. Inject: memory body content present in stdout
7. Recovery R16 idempotent (no duplicate index entry on re-run)
8. All shell scripts pass `bash -n` AND `/bin/bash -n`

## Open questions

None blocking. Future follow-ups (out of scope for this PR; tracked here for visibility):
- **Atomic artifact body write.** `write-artifact.sh:53` uses `cp "$CONTENT_FILE" "$DEST"`, non-atomic for files larger than one filesystem block. Pre-existing for all artifact types (skill/rule/memory). Worth a separate PR converting to `mktemp + mv`.
- **Partial-failure recovery window.** Between `write-artifact.sh` succeeding and proposal archival completing in `approve-proposal.sh`, a process crash leaves the proposal in the LIVE index and DEST on disk; re-run hard-errors in `write-artifact.sh:45-51`. User remediation: delete orphan DEST or proposal entry. Pre-existing; affects all artifact types.
- **Global memory creation flow.** `data/global/memory/` exists but no automated path populates it (clusterer is project-scoped; promoter only emits `type: promotion`). Future: a memory-promoter agent or a manual `/promote-memory` skill.
- **Soft cap on injected memory size.** All memories injected unconditionally per requirements; if memory volume grows large, a `memory.max_total_bytes` config knob with truncation would be a backwards-compatible add. Schema does not need to change.
- **Live `claude-evolve` repo history pollution.** P2 implementer's earlier non-isolated tests pushed 6 commits to the live remote (3 evolve(approve) + 2 reverts + 1 cleanup). User confirmed leave-as-is. The reverts cancel the test data; cleanup removed any stray dirs.
