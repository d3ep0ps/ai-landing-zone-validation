# Evidence review (Phase 6, 2026-10-25)

Three independent `evidence-reviewer` runs (fresh context, repository only), split by test range because of the agent turn limit:

- [part 1](evidence-review-part1.md): T01–T06 — 0 HIGH, 4 MEDIUM, 9 LOW
- [part 2](evidence-review-part2.md): T07–T12 — 5 HIGH, 6 MEDIUM, 7 LOW
- [part 3](evidence-review-part3.md): T13–T17 and the run-log cross-check — 1 HIGH, 4 MEDIUM, 7 LOW

Common results: the expected text is identical across Appendix A, scripts, output headers and result.json in every run; the scripts were committed before the runs they grade (b2d85bb before run 1; 04d260b before run 2); the run-log tables match every result.json; run 1 and run 2 agree for all 17 tests.

Opus verified the T12 claim (E1) and the T07/T10 dates (E2) against the raw output and git before accepting them. Corrections are in [`evidence/runs/errata.md`](../evidence/runs/errata.md).

## HIGH

| # | Test | Issue | Resolution | Status |
|---|---|---|---|---|
| H1 | T14 | Deploy-order claim (trap #7) not demonstrated: A never queried after enforcement | Errata E7; targeted re-test T14R run 3 (pre-registered 701baba): INCONCLUSIVE, agent's own calls refused after enforcement (E8). Report limits T14 to agent B; trap #7 listed as not demonstrated, with the T14R finding | documented |
| H2 | T07 | Expected result changed after run 1; PASS graded against the changed text | Errata E3: report as pre-registered INCONCLUSIVE + PASS against amended expectation; deviation listed | documented |
| H3 | T10 | "Proves trap #4" not shown as written; CMEK refusal only with the regional-bucket attempt added after run 1 | Errata E4: claim scoped to the regional bucket; trap #4 as written not shown | documented |
| H4 | T11 | Tier Enforced on a read-only observation | Errata E5: report tier Configured (observed) | documented |
| H5 | T12 | Recorded analyzer counts (0) contradict raw output (1 path; control 13) | Errata E1; `tests/T12.sh` count fixed and checked on recorded output; verdict unchanged | fixed (future runs) + documented |
| H6 | T12 | Tier Enforced on a FAIL with no attempt | Errata E5: report tier Configured (observed) | documented |

## MEDIUM

| Test | Issue | Resolution |
|---|---|---|
| T01–T04 | Folder not shown as the policy source | Supplement `evidence/supplement/policy-sources-2026-10-25.txt` (post-run, read-only): the only org policy is `iam.allowedPolicyMemberDomains`; no project-level policies; the constraints under test are set only on the test folders |
| T07 | Attribution by elimination not evidenced | Same supplement: no org- or project-level CMEK-related policy. Limitation: taken at base state, after the toggle policy was removed |
| T07/T10 | Change dates wrong | Errata E2; Appendix A corrected with a note |
| T10 | Staging bucket name never captured; expected text satisfied by any failure | Errata E4; limitation |
| T01 | Run-2 cleanup check showed the SA still present (eventual consistency); later proof only in scratch | Limitation; v1.1: retry the describe until NOT_FOUND and keep it in output.txt |
| T02 | Run-1 manual delete of the leftover service only in prose | Limitation (run-1.md records it); later list checks show no services |
| T06 | Cannot show the effect of our policy (Google default) | Errata E5 note; report wording |
| T11/T12/T14 | Agent cleanup and "platform made the grant" only in scratch logs | Limitation; report cites run-1.md/run-2.md Stage 4 lines. v1.1: write the agent list and plan summary into evidence |
| T13 | Dry-run stage log entries not pinned to that stage's requests | Limitation; v1.1: filter by time window and request ID |
| T16 | Tier Documented unsupported | Errata E5: n/a |
| T17 | Enforced covers only the `default` annotation requirement, not image admission | Limitation; report wording |

## LOW

Handled in report wording or limitations, or listed for v1.1: parallel test execution in run 2 (no interference seen); PASS used for sub-results in `actual`; script commit not in output headers; stray `.last-output` helper files; T04 doc ref for the denied model; T05 not honoured at request level; T06 before-stage absence inferred; T08 matcher change after run 1 (deviation list); T09 `actual` text (E6); T11 "unique" by construction; T13 copy simulated through an operator ingress rule; T13 run 1 spans the project replacement; T14 attribution by design; T15 does not show immutable audit-log retention; T17 aborted-folder note; T13 partially masked caller emails in audit entries; T01 run-1 effective read unreadable; T01 run-1-r2 ambiguous post-delete check.

## Gate 6

No open HIGH issue after the T14R re-test (2026-10-25): H1 documented with errata E7/E8. Gate 6 confirmation recorded in PROGRESS.md.
