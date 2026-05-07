# Memory auto-creation -- Implementation Summary

**Created:** 2026-05-07
**Plan:** `PLAN.md` (v3)
**Mode:** Sequential subagents

## Phase status

| Phase | Status | Notes |
|-------|--------|-------|
| Phase 1: Foundation | COMPLETE | First-pass implementation had a critical bug (proposal_id derived from filename); fix-pass corrected to read from YAML `.id`. Both gates pass after fix. |
| Phase 2: PROJECT_ROOT optional + scope | COMPLETE | First-pass had a critical bug (mid-archival recovery suppressed entire archival block); fix-pass added a separate `MID_ARCHIVAL` flag and idempotency guard for archived-index append. Both gates pass after fix. |
| Phase 3: Clusterer restrictions | COMPLETE | Implementer removed 3 additional residual `memory` references in clusterer.md beyond literal MEMORY section (intro line, format comment, format hint) — judgment call to keep the agent prompt internally consistent. Both gates PASS first try. |
| Phase 4: memory-writer agent | COMPLETE | First-pass had two Important issues (regex/prose contradiction on name length; missing preamble prohibition on success path). Fix-pass tightened regex to `{0,59}` and added "MUST begin with `name:`" sentence. Both gates PASS after fix. |
| Phase 5: Global memory approve/reject | COMPLETE | First-pass had 1 Critical (mid-archival flag conflation, same bug pattern as Phase 2) and 2 Important issues (dead PROPOSED_CONTENT variable + missing null guard; missing validate_id on PROPOSAL_ID). Plus an unrelated regression: an earlier subagent's `git checkout` of lib.sh (after a symlink-collision test failure) had wiped Phase 1's lib.sh additions. Fix-pass restored Phase 1 helpers AND addressed Phase 5's Critical+Important issues. Both gates PASS after fix. |
| Phase 6: graduate.sh + unskip + wiring | COMPLETE | First-pass had 2 Critical (`archive_proposal` corrupting global archive index due to source_instincts vs source_global_instincts; global proposal id format could exceed 80-char validate_id limit) and 2 Important issues (grep -P incompatible with macOS BSD grep; `conf=?` in log line). Fix-pass scoped archive_proposal to project only and added inline global archival with correct schema; tightened agent name cap from 60→45 chars; replaced grep -P with awk; threaded confidence through buffers. Then a second-round Important (missing-both-paths edge case in inline global archival) was patched inline with `continue`. All gates PASS. |
| Phase 7: Observability + docs | COMPLETE | First-pass passed both gates with one Important edge-case finding (combined-branch silent omission of unknown-typed global proposals). Patched inline by adding fallback. |
| End-to-end verification | COMPLETE | All 17 plan E2E scenarios + 5 supplementary structural checks PASS (22/22). Reviewer flagged 2 non-blocking Important findings (existing-user upgrade path missing init_global; parse_agent_yaml didn't enforce 45-char cap pre-LLM). Both patched inline: graduate.sh and approve-global-proposal.sh now call init_global defensively; parse_agent_yaml rejects names > 45 chars. |

## Decisions and deviations during implementation

### Phase 2 (2026-05-07)
- **Critical fix during Phase 2**: feature-verifier caught that the new mid-archival recovery branch (`approve-proposal.sh` lines 76-88) set `IS_RECOVERY=1`, which suppressed the entire archival block (`if [[ $IS_RECOVERY -eq 0 ]]; then ...`). Live index would stay dirty after a mid-archival crash. Fixed by introducing a separate `MID_ARCHIVAL=0` flag: mid-archival sets `MID_ARCHIVAL=1` (NOT `IS_RECOVERY=1`); R16 full-recovery still uses `IS_RECOVERY=1`; archival block's outer guard unchanged; file-move steps inside gated on `MID_ARCHIVAL=0`; live-index rewrite and archived-index append always run within the IS_RECOVERY=0 block; added `ALREADY_ARCH` idempotency guard for the archived-index append. Plan didn't anticipate this state-machine subtlety.
- **Defensive guard added**: `write-artifact.sh` rejects empty `PROJECT_ID` when scope=project AND type=memory (prevents writes to `/projects//memory/...`). Not in plan; reasonable defensive addition.
- **Suggestion (deferred)**: code-reviewer noted that `approve-proposal.sh`'s inline archival block (lines 183-226) duplicates `archive_proposal()`'s logic. Follow-up phase could refactor to use the helper. Minor friction: `archive_proposal()` generates its own `resolved_at` and re-reads `SRC_IDS` from YAML; refactor would need to align these. Not blocking.

### Phase 1 (2026-05-07)
- **Critical fix during Phase 1**: code-reviewer caught that `archive_proposal()` derived `proposal_id` from filename (`${basename_file%.yaml}`), but cluster.sh creates proposals with `id != filename` (id `proposal-{name}-{date}` vs file `{name}-{type}.yaml`). Fixed by reading `proposal_id` from `yq '.id'` on the archived copy after the recovery/normal/missing branch, with a filename-derived fallback when `.id` is absent (with WARN log). Plan didn't anticipate this — the plan said "atomic-rewrite the live index removing the proposal entry by id" without specifying where to read the id from.
- Implementer noted: lib.sh has `set -euo pipefail` at the top, which leaks into any sourcing script (e.g., install.sh). install.sh already has `set -euo pipefail` so no impact, but worth noting for future callers.
- Implementer noted: filename-vs-id invariant is undocumented in the codebase but appears to hold. Phase 6 graduate.sh must produce filenames that match the cluster.sh convention or document a divergence.

## Reviewer suggestions: accepted / deferred

### Phase 1
- **Accepted**: feature-verifier and code-reviewer both flagged stale comment `# matches reject-proposal.sh:95` in lib.sh:418 — to be cleaned up during Phase 7 when CLAUDE.md docs are written. Deferred for now.
- **Accepted (post-fix)**: code-reviewer's Critical (proposal_id from YAML) — fix applied; both gates re-passed.
- **Deferred (Suggestion)**: `local sid` declared inside the `for` loop instead of before; cosmetic, no behavior impact.
- **Deferred (Suggestion)**: `reject-proposal.sh` doesn't `validate_id "$PROPOSAL_ID"` (pre-existing issue, not introduced by this phase).

## Open questions and follow-ups (post-merge)

These are intentionally deferred — non-blocking findings that surfaced during review but don't justify holding the merge:

1. **`approve-proposal.sh` inline archival could use `archive_proposal()`.** The script (lines 183-226) duplicates `archive_proposal()`'s logic (file move + index updates + idempotency guard). Refactoring would deduplicate but requires aligning `resolved_at` generation and SRC_IDS sourcing.
2. **`approve-global-proposal.sh` could similarly use a shared helper.** The Phase 6 fix added inline global archival in graduate.sh that mirrors approve-global-proposal.sh's memory-branch logic. Future cleanup could lift both into a shared function (parameterized by `src_field`/`count_field`).
3. **Same-day proposal-id collision for repeated auto-tier promotions of the same instinct.** The archived index has an idempotency guard via `archive_proposal()`/`ALREADY_ARCH`, so the second `superseded_by_auto` entry is silently dropped. Acceptable per plan Risk I-D, but unusual. Mitigated by the fact that auto-tier promotions are rare and same-day collisions for the SAME instinct are rarer still.
4. **Minor schema asymmetry**: project memory proposal yaml omits `name:` (derived from id via sed), but global memory proposal yaml includes `name:` (read directly by approve-global-proposal.sh). Documented deviation; harmless but worth unifying in a future cleanup.
5. **`unskip-instinct.sh --global PROJECT_ID INSTINCT_ID` requires a syntactically valid PROJECT_ID even though it's unused for path resolution.** UX nit — could be relaxed to allow `""` when `--global` is set.
6. **`promote-instinct.sh` (out-of-scope for this feature) emits a non-fatal `flock: data error: Bad file descriptor` to stderr when source-project lock files don't exist.** Surfaced during E2E test 15 (backwards-compat promotion flow). Pre-existing, not a regression.

## End-to-end verification summary

22/22 scenarios PASS (17 plan-defined E2E scenarios + 5 supplementary structural checks). All `bash -n` and `/bin/bash -n` pass on all modified scripts (macOS bash 3.2 compatible). Two non-blocking Important findings from final review were patched inline:
- `graduate.sh` and `approve-global-proposal.sh` now call `init_global` defensively (existing-user upgrade path).
- `parse_agent_yaml` in `graduate.sh` rejects names > 45 chars pre-write (matches the agent prompt's contract; saves a wasted LLM call's downstream).

## Files inventory (final)

**New files:**
- `scripts/graduate.sh` (~931 lines)
- `scripts/unskip-instinct.sh` (~99 lines)
- `agents/memory-writer.md` (~127 lines)

**Modified files:**
- `scripts/lib.sh` — added `archive_proposal()` (with idempotent recovery), `acquire_lock_blocking()`, `EVOLVE_AGENT_MODEL_OVERRIDE` env-var override in `invoke_agent`.
- `scripts/reject-proposal.sh` — refactored to use `archive_proposal()`.
- `scripts/approve-proposal.sh` — `PROJECT_ROOT` optional for memory; mid-archival recovery via `MID_ARCHIVAL` flag; `auto_approve_target` auto-resume signal.
- `scripts/write-artifact.sh` — `--scope project|global` flag (always prepends `global-`); `PROJECT_ROOT` optional for memory.
- `scripts/cluster.sh` — defense-in-depth check rejecting `type=memory` from clusterer.
- `scripts/approve-global-proposal.sh` — `type=memory` dispatch branch with `IS_RECOVERY` semantics; type-discriminated archived-index entry; defensive `init_global` call.
- `scripts/reject-global-proposal.sh` — type-aware archived-index entry (memory uses `source_global_*`).
- `scripts/observe.sh` — `graduate.sh "$PROJECT_ID"` invocation between `promote.sh` and final `evolve_git_push`.
- `scripts/check-proposals.sh` — separate `PROJECT_MEMORY_COUNT`/`GLOBAL_PROMOTION_COUNT`/`GLOBAL_MEMORY_COUNT` queries; surfaces `.graduation-warning` files; drops "promotion" hardcode.
- `agents/clusterer.md` — deleted MEMORY artifact section; updated type enumeration; added boundary note.
- `config.yaml` — added `propose_memory_threshold` and `auto_memory_threshold` under both `instincts:` and `global_instincts:`; added top-level `graduation:` block.
- `install.sh` — sources `lib.sh`; calls `init_global`.
- `CLAUDE.md` — hook flow diagram extended; confidence lifecycle step 7; new sections for Memory Graduation, lib.sh helpers, admin commands, config keys, `--scope global`; obsolete caveat removed.
