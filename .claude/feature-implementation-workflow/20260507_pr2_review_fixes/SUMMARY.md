# PR #2 review fixes -- Implementation Summary

**Created:** 2026-05-07
**Plan:** `PLAN.md` (v3)
**Mode:** Sequential subagents
**Branch:** `feat/memory-graduation` (continuing on PR #2)

## Phase status

| Phase | Status | Notes |
|-------|--------|-------|
| Phase 1: Defensive parsing + validation | COMPLETE | First-pass passed verifier (PASS WITH WARNINGS) but reviewer caught 2 Important gaps: (a) I4-GAP — `validate_id` was applied only to the candidate-loop's domain read; reviewer flagged two more disk reads at graduate.sh:274 (`pf_domain` in resume_orphans dir scan) and :740 (`pend_domain` in global preempt) that flow into yq heredocs and were unguarded. The plan said "any other location where `domain` is read from disk" — implementer missed the other two. (b) I6-GAP — pre-strip empty check ran BEFORE `tr -d '\t\r'`, so a tab-only title/description bypassed the guard and wrote empty strings downstream. Fix-pass added all three validate_id guards plus a post-strip empty check after the tr lines. 26/26 tests pass (8 + 5 + 13). Both gates PASS after fix. |
| Phase 2: archive_proposal generalization | COMPLETE | First-pass passed verifier on 36+14 tests but missed two issues: (a) verifier-Critical: `local sgi` declared inside for-loop and `local spi_proj spi_inst` inside its loop caused bash 3.2 stdout leakage on iterations >= 2 — `archive_proposal` would emit `varname=value` to stdout for any global proposal with 2+ source entries. Test suite missed it because no test asserted stdout cleanliness. (b) reviewer-Important: silent file clobber when recovery branch had both live AND archive paths populated — no log line. Reviewer also raised a misread concern about an idempotency guard preempting Phase 4; investigated and confirmed Phase 4 modifies approve-*.sh INLINE (not via archive_proposal), so the guard is correctly scoped to reject-* idempotency only — kept guard with explanatory 9-line comment. Fix-pass moved both `local` declarations before their loops, added INFO log on clobber, removed a stale Phase 1 test that grep'd for now-deleted inline code. 78/78 tests pass after fix. Both gates PASS. |
| Phase 3: Per-tick unique proposal ids | COMPLETE | First-pass passed verifier (PASS WITH WARNINGS) but reviewer caught Critical regression: `approve-proposal.sh:113` was switched from sed-based id-stripping to `yq '.name'` read, but `cluster.sh` proposals had no `name:` field — would `exit 1` on every cluster-created proposal approval. Implementer added `name: ${f_name}` to graduate.sh's project heredoc but missed cluster.sh. Fix-pass added `name: ${name}` to cluster.sh's proposal yaml heredoc and updated CLAUDE.md archive_proposal signature (5-arg → 6-arg + --scope global). Implementer also (correctly) extended global heredoc with `name:` even though plan only required project. Test count: 26/26 (4 new cluster-style tests added). Both gates PASS after fix. |
| Phase 4: Idempotency-guard upgrade | COMPLETE | First-pass cleanly replaced ALREADY_ARCH boolean with 6-branch status dispatch in both approve-proposal.sh (lines 207-268) and approve-global-proposal.sh (lines 346-450). Reviewer caught two Important issues: (a) `tmp_idx` variable shadowing risk in the `superseded_by_auto` branch (same name used earlier for live-index rewrite, fragile if future code interleaves) — renamed to `tmp_arch_idx` in both files. (b) Phase 1's I8 `-f`→`-e` fix was missed for `approve-global-proposal.sh:188` (Phase 1 plan only specified approve-proposal.sh:153) — fixed for symmetry. 53 Phase 4 tests + all prior pass. Both gates PASS after fix. |
| Phase 5: Resume-orphans shift-safe iteration | COMPLETE | First-pass restructured `resume_orphans` index-scan from position-based for-loop to Phase A (collect ids under lock) + Phase B (process per-id with release/reacquire). Implementer caught a plan deviation: PLAN had `auto_approve_attempts` read from live index (B.2), but that field lives on the proposal yaml — reordered to resolve `prop_path` first, then read attempts from yaml. Reviewer caught Important issue: Phase B resolved prop_path and bumped attempts but didn't re-check the yaml's `status` AND `auto_approve_target` after Phase A's collection — a proposal manually set to `rejected` between Phase A and Phase B would still get its counter bumped. Fix-pass added B.2a re-check block at graduate.sh:232-240. 34/34 tests pass on test_phase5_c3.sh. Both gates PASS. Note: dir-scan path was deliberately left untouched because it iterates files (not by index position) and doesn't have the same shift bug. |
| Phase 6: End-to-end verification + docs | COMPLETE | E2E feature-verifier (opus) ran the full Phase 1-5 test inventory (~191 tests) plus 11 cross-phase scenarios A-K. ALL passed. Code-reviewer (opus) found 2 Important issues to fix before merge: (a) I-1 — graduate.sh:805 used `$?` inside `if !` block, always logging `rc=0` instead of the real archive_proposal exit code; (b) I-2 — lib.sh:455 archive_proposal's live-index rewrite did `mv "$tmp_live" "$live_index"` without checking that yq produced non-empty output, so a silent yq parse failure would clobber the live index. Fix-pass replaced the `if !` pattern with `arch_rc=0; ... || arch_rc=$?; if [[ $arch_rc -ne 0 ]]; ...` (matching reject-global-proposal.sh:78-86), and added `elif [[ ! -s "$tmp_live" ]]` empty-output guard with `return 1`. Reviewer also flagged 3 deferred Importants (I-3 archive_proposal prop_domain unvalidated; I-4 graduate.sh dir-scan pf_id/pf_type unvalidated in heredoc; I-5 documentation of behavior shifts) — accepted as post-merge follow-ups. Both gates PASS after fix. |

## Decisions and deviations during implementation

### Phase 1
- **Plan said "any other location where domain is read from disk in graduate.sh"; implementer initially missed two of three sites.** Caught by reviewer: pf_domain at the resume_orphans dir-scan and pend_domain at the global preempt inline path. Fix-pass added validate_id guards at all three locations.
- **I6 placement bug in first-pass.** Pre-strip empty check ran BEFORE the `tr -d '\t\r'` strip, so a tab-only title would bypass the guard. Fix-pass added a post-strip empty check.

### Phase 2
- **Critical bash 3.2 stdout leakage.** Implementer initially declared `local sgi` and `local spi_proj spi_inst` INSIDE for-loop bodies. On bash 3.2 (macOS), this prints `varname=value` to stdout on iterations >= 2 — silently corrupting any caller that captures stdout. Fix-pass moved declarations BEFORE the loops (matching the project branch's existing pattern).
- **Reviewer raised a phantom concern about idempotency-guard preempting Phase 4.** Investigation confirmed Phase 4 modifies approve-*.sh INLINE and never calls archive_proposal — so the guard is correctly scoped to reject-* idempotency. Kept guard with explanatory 9-line comment.
- **DELIBERATE behavior shifts** in two places: reject-global-proposal.sh changed from "exit 1 on missing live" to "self-heal via recovery branch"; graduate.sh global preempt changed from "skip silently when archived already exists" to "self-heal indexes". Both improvements; documented inline.

### Phase 3
- **Implementer correctly added `name: ${f_name}` to project proposal heredoc** (deviation from plan, but coherent — approve-proposal.sh's new yq read needs the field). Implementer also added it to the global heredoc proactively.
- **Reviewer caught a regression**: cluster.sh's proposal yamls had no `name:` field, breaking approve-proposal.sh on every cluster-created skill/rule proposal. Fix-pass added `name: ${name}` to cluster.sh's heredoc immediately after `id:`.
- **CLAUDE.md archive_proposal signature was stale** (showed old 5-arg). Updated to 6-arg + --scope global.

### Phase 4
- **Reviewer caught variable-name shadowing risk** with `tmp_idx` reused for both live-index and archived-index temps in the same function. Fix-pass renamed to `tmp_arch_idx` in the superseded_by_auto branch (4 places per file).
- **Phase 1's I8 (-f→-e) fix was missed for approve-global-proposal.sh:188** — Phase 1 plan only specified approve-proposal.sh:153, but symmetry calls for both. Fixed in this phase's fix-pass.

### Phase 5
- **Plan-pseudocode bug**: PLAN.md had B.2 read `auto_approve_attempts` from the live index, but that field actually lives on the proposal yaml. Implementer correctly reordered to resolve `prop_path` first, then read attempts from the yaml.
- **Reviewer caught missing yaml-status re-check**: a proposal manually transitioned to `rejected` between Phase A's id collection and Phase B's processing would have its attempt counter bumped and the approve script called. Fix-pass added a B.2a re-check block (reads `.status` and `.auto_approve_target` from yaml; skips with INFO if not pending/true).

### Phase 6
- **Reviewer caught broken `$?` capture**: `if ! archive_proposal ...; then evolve_log "(rc=$?)"; fi` always logged rc=0 because `$?` inside the `then` is the negation operator's exit code. Fix-pass switched to the existing `arch_rc=0; ... || arch_rc=$?` pattern.
- **Reviewer caught missing empty-output check** in archive_proposal's live-index rewrite — silent yq parse failure could clobber the live index to empty. Fix-pass added `elif [[ ! -s "$tmp_live" ]]; then ... return 1`.

## Reviewer suggestions: accepted / deferred

### Accepted (applied)
- Move `local` declarations before for-loops (Phase 2)
- Add INFO clobber log on recovery file move (Phase 2)
- Rename `tmp_idx` to `tmp_arch_idx` in superseded_by_auto branch (Phase 4)
- `-f` → `-e` symmetry in approve-global-proposal.sh:188 (Phase 4)
- B.2a yaml-status re-check (Phase 5)
- `arch_rc=$?` capture pattern (Phase 6)
- Empty-output guard in archive_proposal live-index rewrite (Phase 6)

### Deferred (post-merge follow-ups)
- **I-3**: archive_proposal's `prop_domain` is read from disk and flows into yq heredocs unvalidated. Phase 1's I4 added validate_id at three graduate.sh sites; the helper itself doesn't have the same guard. Defense-in-depth gap; trust boundary depends on no manual proposal-yaml tampering.
- **I-4**: graduate.sh dir-scan path uses unvalidated `pf_id` and `pf_type` from disk in a yq heredoc. Same class of issue as I-3.
- **I-5**: behavior shift in reject-global-proposal.sh for unknown types (helper writes 6-field minimal entry vs old `promotion|*` fallthrough writing source_project_*) — undocumented in CLAUDE.md, low priority since approve-global-proposal.sh blocks unknown types upstream.
- **S-2**: 9-line idempotency-guard comment in lib.sh could be condensed to ~3 lines.
- **S-3**: recovery-branch clobber log is INFO-level; reviewer suggests promoting to WARN since it represents data loss (archived copy overwritten).
- **S-5**: archive_proposal returns 1 vs 2 distinctly but no caller distinguishes; either document or collapse to single non-zero.

## Open questions and follow-ups (post-merge)

These are intentionally deferred — non-blocking and out of scope for this PR:

1. **I-3, I-4 (defense-in-depth)**: validate_id guards on archive_proposal's `prop_domain` read AND on graduate.sh dir-scan's `pf_id`/`pf_type` reads. Both are defense against manual proposal-yaml corruption, low likelihood, easy follow-up.
2. **I-5 (documentation)**: CLAUDE.md should briefly describe the deliberate behavior shifts in reject-global-proposal.sh (error→self-heal) and graduate.sh global preempt (skip→self-heal).
3. **Approve scripts could use shared archival helper** (carried over from PR #2's open question #1+#2). This PR partially resolved by moving reject-* and graduate.sh global preempt to the helper; approve-* scripts retain inline logic because they have richer outer flow (IS_RECOVERY/MID_ARCHIVAL/artifact-write/instinct-archival). Future cleanup could extract a shared core.
4. **`unskip-instinct.sh --global PROJECT_ID INSTINCT_ID` requires syntactically valid PROJECT_ID** even when `--global` makes it unused. Carried over from PR #2.
5. **Test scripts in `/tmp/`** are ephemeral and disappear between sessions. Consider promoting select scenarios to a `tests/` directory with a runner. Out of scope here, but the implementation produced ~200+ tests of value worth preserving in some form.

## End-to-end verification summary

- **bash -n + /bin/bash -n** (macOS bash 3.2 compat) on all 7 modified scripts: PASS.
- **Per-phase tests** (Phase 1-5): ~191 assertions across 8 test scripts, all PASS.
- **Cross-phase scenarios A-K** (E2E feature-verifier): 11/11 PASS. Covers: same-day propose→auto with new ids, legacy collision status upgrade, 3-orphan resume, mid-tick rejection re-check, cluster-style proposal name field, validate_id fallback, fence-strip, status-enum defense, scope=global promotion schema, reject-global recovery.
- **Regression spot-checks** against the prior PR's 22 E2E scenarios: PASS.
- **File inventory**: matches plan exactly (lib.sh, graduate.sh, approve-proposal.sh, approve-global-proposal.sh, reject-proposal.sh, reject-global-proposal.sh, cluster.sh, CLAUDE.md). agents/, config.yaml, install.sh deliberately untouched.
- **Final reviewer + verifier round**: both APPROVE/PASS after the I-1/I-2 fix-pass.

## Files inventory (final)

**Modified (8 files):**
- `scripts/lib.sh`: archive_proposal generalized to 6-arg signature with status-enum validation + optional --scope global flag; type-dispatched archived-index schema for project/global×memory/promotion/unknown; `local` declarations before for-loops; INFO clobber log; empty-output guard on live-index rewrite.
- `scripts/graduate.sh`: Phase 1 (fence-strip both sites, 3 validate_id guards on domain reads, PARSE_OK removal, control-char strip with post-strip empty check, return 0 in 4 helpers); Phase 2 (project + global preempt both call archive_proposal with explicit id; arch_rc capture pattern); Phase 3 (EPOCH_NOW capture; epoch-suffix proposal_id format for both project and global; `name: ${f_name}` in both heredocs); Phase 5 (resume_orphans index-scan restructured to Phase A id-collection + Phase B per-id processing with B.1 + B.2a re-validation, cap-then-bump, content_file lifecycle, `if !` wrapper, empty-array idiom).
- `scripts/approve-proposal.sh`: Phase 1 (`-f` → `-e` recovery skip guard); Phase 3 (PROP_NAME from yq `.name` instead of sed); Phase 4 (ALREADY_ARCH boolean replaced with 6-branch status-aware case dispatch; `tmp_arch_idx` rename in superseded_by_auto branch; exit 1 on rejected/permanently_rejected/unknown).
- `scripts/approve-global-proposal.sh`: Phase 3 (NOTE comment about why promotion-branch sed stays); Phase 4 (same status dispatch as approve-proposal.sh, with type-discriminated schema nested in `""` branch; `tmp_arch_idx` rename); Phase 4 fix (`-f` → `-e` for symmetry with approve-proposal.sh).
- `scripts/reject-proposal.sh`: Phase 2 (passes proposal_id explicitly to archive_proposal).
- `scripts/reject-global-proposal.sh`: Phase 2 (replaced inline archival block with `archive_proposal --scope global` call; removed missing-file hard-error guard — DELIBERATE shift to self-heal).
- `scripts/cluster.sh`: Phase 3 fix (added `name: ${name}` to proposal yaml heredoc — required for approve-proposal.sh's new yq `.name` read to work for skill/rule proposals).
- `CLAUDE.md`: documented new proposal_id format (Memory Graduation section) and updated archive_proposal signature/docs to reflect 6-arg + --scope global.

**No-touch (per plan):** `agents/`, `config.yaml`, `install.sh`, all of Phase 1/2/3 of the prior PR's untouched files.

**Statistics:** 550 insertions, 362 deletions across 9 files (8 scripts + CLAUDE.md). Net +188 lines.
