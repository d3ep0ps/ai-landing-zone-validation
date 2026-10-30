# AI Landing Zone Reference Validation

This repository holds reproducible evidence that a set of AI landing zone controls behave as configured in a reference Google Cloud organization: the reference environment, the tests that were run, the results, and the limitations.

- Results table: [results.md](results.md)
- Limitations and untested items: [limitations.md](limitations.md)
- Environment: [environment.md](environment.md)

## Headline results

Each run has 17 tests. The final verdicts are identical in run 1 and run 2: 15 PASS, 1 FAIL (T12) and 1 NOT_TESTED (T16, deferred). A third sitting, T14R, re-tested the agent deploy-order claim and ended INCONCLUSIVE. Some PASS verdicts carry qualifications (for example T07 passed against an expected result amended after run 1); read [results.md](results.md) and [evidence/runs/errata.md](evidence/runs/errata.md) before citing a verdict.

v1.1 (design changes for the gaps v1 found; `EXECUTION-PLAN.md` Appendix D) added 9 tests, run twice. Run 4 (2026-10-25..26): 8 PASS and 1 INCONCLUSIVE (T22). Run 5, the repeat (2026-10-26..27): the same 8 PASS and 1 FAIL (T22). T22 saw the same behaviour in both runs (a Terraform plan with the quota project inside the enforced perimeter was refused on the lookup of the project outside it); run 4 recorded INCONCLUSIVE because of script faults, fixed before the run-5-r2 verdict. T16 (Secure Web Proxy) in run 4 ran last, after Google reinstated the runtime project, which it had suspended after the other run-4 tests. See the v1.1 section of [results.md](results.md).

Run 6 (2026-10-27..28) ran all tests, v1, v1.1 and v2, in one order: 38 results, 30 PASS, 3 FAIL (T12, T22, T29), 5 INCONCLUSIVE (T14R, T34, T30, T31, T32), 0 NOT_TESTED.

- v1 and v1.1 tests repeated their earlier verdicts: T12 FAIL again (the analyzer now finds the path: 1 result, control query 19), T22 FAIL again (same finding as run-5-r2), T14R INCONCLUSIVE again, T16 PASS.
- v2 tests (`EXECUTION-PLAN.md` Appendix E): 7 PASS (T27, T28, T33, T36, T37, T38, T39 with T39b), 1 FAIL (T29: Model Armor blocked the prompt, but the message prefix differs from the pre-registered text), 4 INCONCLUSIVE (T30, T31, T32: an agent behind an Agent Gateway got 401 UNAUTHENTICATED after the gateway authorised its calls, so nothing about gateway controls is shown; T34: no firewall log entry at all).

Run 7 (2026-10-28..29) ran all 38 tests again, as the second v2 run (E5 item 4): the same verdict for every test as run 6, with no retries.

- Area B (T30, T31, T32) ran with a changed setup: the agent opts out of certificate-bound tokens, its packages are pinned, and the gateway uses IAP policy V2. No 401 was seen. A post-run lookup of the gateway log showed IAP V2 refusing an unregistered MCP server and a blocked model endpoint (403); the tests' own log checks did not isolate those entries. The tests are still INCONCLUSIVE: the registered MCP server on Cloud Run was unreachable from the gateway (404), because the landing zone allows only internal Cloud Run ingress and the gateway had no VPC egress.

Run 8 (2026-10-30) re-ran only the gateway tests, adding VPC egress for the gateway (network attachment, PSC endpoint for Google APIs, private `run.app` zone): T30 PASS (unregistered MCP tool refused at the gateway, registered tool answered), T32 PASS (an injected tool response blocked by the gateway's Model Armor screen), T31 INCONCLUSIVE (both clauses seen, but not in one attempt: in the later attempts the blocked call's 403 had no gateway log entry, so it could not be attributed to the gateway). One run with this setup.

Run 9 (2026-10-30) repeated run 8 with the same setup: T30 PASS and T32 PASS again (two runs each), T31 PASS (both clauses in one attempt), and T31R INCONCLUSIVE (a re-test that changes only the gateway registry: after registration the gateway's 403 was replaced by a Vertex AI 404 (the test's model was not found on the regional endpoint, or the project has no access), not the expected 200).

See the v2 section of [results.md](results.md).

## Repository map

| Path | Content |
|---|---|
| `infra/` | Terraform for the reference environment; `infra/agents/` for the paid agent deployments |
| `tests/` | One script per test (`TNN.sh`), `lib.sh`, fixtures, [RUN-ORDER.md](tests/RUN-ORDER.md) (v1), [RUN-ORDER-v11.md](tests/RUN-ORDER-v11.md) (v1.1), [RUN-ORDER-run6.md](tests/RUN-ORDER-run6.md) and [RUN-ORDER-run7.md](tests/RUN-ORDER-run7.md) (all tests, v2), [RUN-ORDER-run8.md](tests/RUN-ORDER-run8.md) and [RUN-ORDER-run9.md](tests/RUN-ORDER-run9.md) (area B) |
| `evidence/TNN/` | Per test and run: `command.txt`, `output.txt`, `result.json` |
| `evidence/runs/` | Run summaries (`run-1.md`, `run-2.md`, `run-3.md`, `run-4.md` and `run-5.md` for v1.1, `run-6.md` and `run-7.md` for all tests, `run-8.md` and `run-9.md` for area B) and [errata.md](evidence/runs/errata.md) |
| `evidence/environment/` | Redacted environment snapshot and plan summary |
| `evidence/supplement/` | Read-only policy-scope listing taken after the runs |
| `tools/` | `redact.py` (with tests) and `snapshot-env.sh` |
| `notes/` | Working notes, doc verification, evidence reviews |
| `EXECUTION-PLAN.md` | The plan, including the test catalogue (Appendix A), the v1.1 design changes and tests (Appendix D), and the v2 design and tests (Appendix E) |

## Evidence standard

Defined in `EXECUTION-PLAN.md` section 4.

- The expected result is written in the test script before it runs.
- Each test writes `command.txt`, `output.txt` and `result.json`.
- Verdicts: PASS, FAIL, INCONCLUSIVE, NOT_TESTED. Tiers: Enforced (the forbidden action was attempted and refused), Configured (the setting is present, read back; no refusal shown), Documented (documentation only). Where a recorded tier does not fit this definition, the report tier in [results.md](results.md) follows the errata.
- An observed difference from the expected result is recorded as a finding. Expected results are not edited after a run. One expected text was changed after run 1 with human approval (T07); it and the other changes to scripts and attempts are listed under "Deviations" in [results.md](results.md).
- Corrections found in review are in [evidence/runs/errata.md](evidence/runs/errata.md); recorded evidence is not edited.
- Evidence is redacted with `tools/redact.py` before it is committed.

## Reproduce in your own organization

Prerequisites: a Google Cloud organization where you can create a folder, projects, org policies and access policies; a billing account (a limit of 5 linked projects hit us once); roles for the operator at organization level; Terraform, gcloud, jq, Python 3 and ShellCheck; the Cloud Foundation Fabric checkout at the commit in [environment.md](environment.md) placed in `vendor/fabric`; a budget alert on the billing account.

1. Copy `infra/terraform.tfvars.example` to `infra/terraform.tfvars` and fill in your organization, billing account and prefix. Read [infra/README.md](infra/README.md) for decisions you must make (quota project, allowed model, irreversible log bucket lock).
2. Apply the base state with all toggles off. Verify folders, effective policies, the dry-run perimeter and the log bucket before testing.
3. Follow [tests/RUN-ORDER.md](tests/RUN-ORDER.md) stage by stage (v1.1: [tests/RUN-ORDER-v11.md](tests/RUN-ORDER-v11.md); all tests including v2: [tests/RUN-ORDER-run7.md](tests/RUN-ORDER-run7.md)). The v2 tests change settings at organization scope (a custom constraint and policy, a Model Armor floor); apply each organization-level change alone, one at a time, only in an organization with no production workloads, and use a second run to repeat the results. v1.1 creates KMS key rings, which cannot be deleted; they go only when their project is deleted. Terraform applies are done by a human; the scripts never apply. Wait at least 15 minutes after each org-policy or perimeter change.
4. Return to base state in Stage 4 and check for leftovers.
5. Redact before publishing: `python3 tools/redact.py FILES...` on the files you will commit (tracked files and `evidence/T*/run-*/`), then `python3 tools/redact.py --check FILES...`. Never run it on `infra/` as a whole: it would rewrite your tfvars and Terraform state. Rules and placeholders: `EXECUTION-PLAN.md` Appendix B.

Safety rules:

- Use a dedicated test folder and apply policies to that folder only.
- Before any command that changes cloud state, check that the active gcloud configuration, account and organization are the ones you intend.
- Do not use `--quiet` on create or delete commands. The one exception here is the cleanup delete of a Cloud Run service the same test script created, by exact name (`cleanup_run_service` in `tests/lib.sh`).
- Do not create or keep service account keys. Do not write tokens or secrets to files.
- Create paid resources only in the phase that needs them and destroy them the same day.
- Never change an expected result after a run; record the difference as a finding.
- Locking the log bucket cannot be undone, and a locked bucket cannot be deleted (observed 2026-10-25: "Locked buckets currently cannot be deleted"). Put it in a project you are willing to delete.
- Do not push evidence that has not been redacted.

## What this does not prove

- It covers one small test organization, not a large or varied one.
- Policies under test in v1 and v1.1 were applied at folder scope. Two v2 tests (T36, T38) used organization scope, once per run (runs 6 and 7), in a test-only organization with no production workloads.
- One region (`europe-west1`, model calls via `global`).
- Results are point-in-time (October 2026). Platform behaviour, error messages and constraint support can change.
- Repeated runs on one environment (v1: runs 1, 2, 6, 7; plus one re-test) show repeatability there, not in other organizations. The v1.1 tests ran twice (run 4 and run 5) on the same environment, with the second run in a different order and with script fixes between them.
- v2 results rest on two runs (6 and 7) on the same environment. Agent Gateway controls (T30, T31, T32) were not shown in runs 6 and 7: INCONCLUSIVE in run 6 (401 from Vertex AI) and in run 7 (registered MCP server unreachable from the gateway; changed setup). In runs 8 and 9, with the agent's token-binding opt-out, IAP V2 and gateway VPC egress, T30 and T32 passed twice; T31 passed once (run 9); T31R was INCONCLUSIVE (fixture fault). T34 does not show that the firewall rule blocks the agent's direct traffic.
- The operator keeps two organization-level roles and one test service account after runs 6 and 7 (human decision 2026-10-28; pending review), plus `roles/iam.accessPolicyAdmin` on the runtime project for IAP V2, which departs from the plan's teardown step.
- Items marked FAIL, INCONCLUSIVE or NOT_TESTED, and everything in "Not tested in v1", are listed in [limitations.md](limitations.md).
- A PASS shows that a specific attempt had the stated outcome. It does not show that no other path exists.
