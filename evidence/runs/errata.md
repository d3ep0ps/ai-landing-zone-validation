# Errata (Phase 6, 2026-10-25)

Corrections found by the independent evidence review (`notes/evidence-review.md`). Recorded evidence (`evidence/TNN/run-*/`) is not edited; where a recorded field is wrong, this file is the correction and the report must use it.

## E1. T12: analyzer counts recorded as 0 are wrong (runs 1 and 2)

- Recorded: `result.json` `actual` "control results=0 … analyzer found path=0"; run-1.md "positive control also 0 results, so analyzer evidence is not validated"; run-2.md "analyzer 0 paths".
- Raw output (`evidence/T12/run-1/output.txt` and `run-2/output.txt`, same line numbers in both):
  - positive control (lines 477–877): 13 ACL results;
  - agent query `--permissions=aiplatform.endpoints.predict` (lines 878–912): 1 result, the agent principal gets `aiplatform.endpoints.predict` through `roles/aiplatform.agentDefaultAccess` bound to the project-wide agent principalSet;
  - agent query `--roles=roles/aiplatform.expressUser,roles/aiplatform.user` (lines 914–917): 0 results (`[]`).
- Cause: `tests/T12.sh` counted `.mainAnalysis.analysisResults`; gcloud prints a status line and then a top-level JSON array, so the count was always 0.
- Effect on verdict: none. FAIL stands and is now supported twice: the fleet grant in the IAM policy and the analyzer path. The positive control worked, so there is no "control failed" limitation.
- Fix: `tests/T12.sh` `analysis_count()` (2026-10-25), checked against the recorded output above. Applies to future runs only.

## E2. T07 and T10: change dates

- Appendix A and run-1.md give 2026-10-23 for the T07 expected-result change and the T10 attempt-2 change. Git (UTC): T07 spec change committed 2026-10-24T05:40:57Z (T07 run 1 was 2026-10-23T21:27Z); T10 attempt 2 committed 2026-10-24T05:46:14Z (T10 run 1 was 2026-10-24T05:44:31Z). Appendix A corrected in place with a note.

## E3. T07: expected result changed after run 1

- Pre-registered expected: "Denied; error names `gcp.restrictNonCmekServices`". Run 1 was INCONCLUSIVE because neither the error nor the audit log names the constraint. The expected text was then changed to the observed Cloud Storage message (human approved) and run-1-r2 and run-2 PASS against the changed text.
- Report wording: "pre-registered result INCONCLUSIVE (finding: the refusal does not name the constraint); PASS against an expected result amended after run 1". Never an unqualified PASS. This is a deviation from the rule "never change an expected result after a run".

## E4. T10: claim scope

- The pre-registered claim "proves article trap #4" (CMEK policy breaks Cloud Build's implicit staging bucket) was not shown as written: in every run the default `gcloud builds submit` was refused by `gcp.resourceLocations` (default bucket in `us`) before CMEK was evaluated. The CMEK refusal was shown only with `--default-buckets-behavior=regional-user-owned-bucket`, an attempt added after run 1.
- The bucket name the build tried to create was never captured (Appendix A asked for it).

## E5. Tier corrections for the report (result.json unchanged)

| Test | Recorded tier | Report tier | Why |
|---|---|---|---|
| T11 | Enforced | Configured (observed) | identity read only; nothing forbidden attempted |
| T12 | Enforced | Configured (observed) | read-only IAM inspection on a FAIL; no attempt |
| T16 | Documented | n/a | not researched; no doc refs |

T06 stays Configured but the report must say the setting was already enforced by Google default before our folder policy, so the test cannot show the effect of our policy.

## E6. T09: `actual` text

- `result.json` says "terms named: none"; the error text is "The member bindings allUsers and allAuthenticatedUsers are not allowed since public access prevention is enforced." The summary grep looked only for camelCase names; the verdict matcher is correct.

## E7. T14: deploy-order claim not demonstrated

- Agent A was queried only while the perimeter was dry-run; after enforcement only agent B was queried. So "an agent deployed before the perimeter keeps internet access" (article trap #7) is not demonstrated in runs 1 and 2. What is shown: an agent deployed inside the enforced perimeter has no internet access (`Errno 101 Network is unreachable`) while its query is allowed.
- Human decision 2026-10-25: add a targeted re-test (query agent A after enforcement), with its expected result written before it runs, in a later session.

## E8. T14R (run 3): result and finding

- T14R (pre-registered in 701baba): pre PASS (agent A, deployed while the runtime project was in no perimeter, fetched https://example.com, tool status 200); post INCONCLUSIVE; final INCONCLUSIVE.
- The recorded `reason` ("LLM may not have called the tool") is the script's generic text. The cause is in the output (line 205): the agent's response carries a VPC-SC 403. A read-only lookup after the result (`evidence/T14R/run-3/post-audit-lookup.txt`) shows the refused call: caller = agent A's own principal, `aiplatform` `SessionService.CreateSession`, ingress violation `NO_MATCHING_ACCESS_LEVEL`.
- Finding: an agent deployed before its project joins a perimeter is treated as a caller outside the perimeter once the perimeter is enforced. Its own Vertex AI calls are refused, so the agent stops working; whether it keeps internet egress could not be observed. The documented trap ("continues to have access to the public internet") was therefore neither reproduced nor disproved. Human decision 2026-10-25: reset the same day, no further variant.
- T14's claim stays limited to: an agent deployed inside the enforced perimeter has no internet access while its query is allowed (runs 1 and 2).
