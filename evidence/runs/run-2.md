# Run 2

- Date: 2026-10-25 (run 1: 2026-10-23..24). Scripts at commit 04d260b. Order: tests/RUN-ORDER.md.
- Stage 1 start 2026-10-25T04:37Z. Last org-policy/perimeter apply: Stage 4 reset on 2026-10-24 (>15 min wait).
- Pre-check (read-only, scratch/run2-precheck.txt): config lz-validation, account and org match PROGRESS.md; 6 always-on folder policies; perimeter lzv_ai dry-run, no status resources, no ingress; budget test-budget USD 50 present. ADC login expired at start (needed only for the agents apply).
- ADC re-login by human 04:38Z (quota project seed).
- T04 inputs (recorded before the run, same as run 1): T04_DENIED_MODEL=gemini-4-argon, T04_LOCATION=global.

## Results

| Test | Verdict | Tier | Evidence | Note |
|---|---|---|---|---|
| T01 | PASS | Enforced | evidence/T01/run-2/ | runtime2; SA describe right after delete still returned it (eventual consistency); later list clean |
| T02 | PASS | Enforced | evidence/T02/run-2/ | no lzv-t02 service left |
| T03 | PASS | Enforced | evidence/T03/run-2/ | no lzv-t03 service left |
| T17 | PASS | Enforced | evidence/T17/run-2/ | refusal names the org constraint; control deleted |
| T04 | PASS | Enforced | evidence/T04/run-2/ | gemini-3.5-flash 200; gemini-4-argon (global) 400 vertexai.allowedModels |
| T08 | PASS | Enforced | evidence/T08/run-2/ | us-central1 bucket 412 naming constraints/gcp.resourceLocations; nothing left |
| T09 | PASS | Enforced | evidence/T09/run-2/ | 412 "...not allowed since public access prevention is enforced"; result.json `actual` says "terms named: none" because the summary grep only looks for camelCase names (same in run 1; verdict matcher is correct). Fix the summary text in Phase 5/7 wording, not in evidence |
| T15 | PASS | Enforced | evidence/T15/run-2/ | retention 1->2 days denied on locked bucket; stays 1 day |
| T06 before | stage ok | | evidence/T06/run-2/ | effective enforce=true at folder and mcp before our policy (same as run 1) |
| T13 setup, dryrun | stages ok | | evidence/T13/run-2/stages/ | 2 buckets kept for 3a/3b (data + outside); dry-run violations logged NO_MATCHING_ACCESS_LEVEL |
- Step 8: human applied infra/agents plan-a-run2.tfplan (1 add: agent A only, no IAM grants), complete 04:43Z; apply log scratch/apply-a-run2.txt.
| T11 | PASS | Enforced | evidence/T11/run-2/ | agent identity principal:// (agents.global), no SA email; TF and REST match |
| T12 | FAIL | Enforced | evidence/T12/run-2/ | same as run 1: platform grants roles/aiplatform.agentDefaultAccess to the project agents principalSet; analyzer 0 paths |
| T14 a | stage ok | | evidence/T14/run-2/stages/a.json | first attempt: fetch_url https://example.com HTTP 200 (run 1 needed r3) |

## Stage 2

- Human-requested apply of plan-stage2-run2.tfplan (3 add: T05/T06/T07 folder policies), run by Opus after config/account/ADC guard; complete 04:45Z. Wait until >= 05:00Z before tests.
- Wait done 05:00Z (15 min after apply). Stage 2 tests start.

| Test | Verdict | Tier | Evidence | Note |
|---|---|---|---|---|
| T05 | PASS | Configured | evidence/T05/run-2/ | effective deny-all at folder and runtime2; read-only |
| T06 | PASS | Configured | evidence/T06/run-2/ | enforce=true after; same before (Google default), as run 1 |
| T07 | PASS | Enforced | evidence/T07/run-2/ | 412 CMEK required; attribution by elimination (constraint not named, as run 1); bucket gone |
| T10 | PASS | Enforced | evidence/T10/run-2/ | attempt 1 (default bucket) blocked by gcp.resourceLocations (as run 1); attempt 2 (regional bucket) CMEK signature; no new cloudbuild buckets |

## Stage 3a

- Human applied plan-stage3a-run2.tfplan (perimeter lzv_ai enforced: 3 projects, storage + aiplatform), complete 05:02Z. Wait 15 min before T13 outside-read.
- Wait done 05:18Z. T13 outside-read starts.
- ADC re-login by human 05:19Z.
| T13 outside-read | stage ok | | evidence/T13/run-2/stages/outside-read.json | ingress NO_MATCHING_ACCESS_LEVEL, storage.objects.get; audit-log entry found on query try 2 (run 1 needed r2 for the filter fix) |

## Stage 3b

- 05:20Z: operator ingress rule (operator user, any source, storage + aiplatform, resources *) added to lzv_ai status and dry-run spec with `gcloud access-context-manager perimeters [dry-run] update --set-ingress-policies` (human approved, same rule and method as run 1; log scratch/ingress-apply-run2.txt). Describe: status 3 projects, 1 ingress; spec 1 ingress. tfvars vpc_sc_operator_ingress = true to match. Wait 15 min before T13 copy.
- Wait done 05:35Z. T13 copy starts.
| T13 | PASS | Enforced | evidence/T13/run-2/ | copy refused RESOURCES_NOT_IN_SAME_SERVICE_PERIMETER, egress target = outside project (billed inside perimeter); both buckets 404 after cleanup |
- 05:40Z: agent B deployed (human asked Opus to apply plan-b-run2.tfplan: 1 add, agent A unchanged; guard ok; log scratch/apply-b-run2.txt).
| T14 | PASS | Enforced | evidence/T14/run-2/ | A (deployed before enforcement) 200 on first attempt; B (deployed inside enforced perimeter) URLError Errno 101 Network is unreachable; query HTTP 200 |
| T16 | NOT_TESTED | Documented | evidence/T16/run-2/ | deferred to v1.1 (as run 1) |

## Stage 4

- 05:42Z: agents A and B destroyed (human approved Stage 4; plan 0/0/2, both reasoning engines only; log scratch/apply-stage4-agents-run2.txt).
- 05:42Z: perimeter reset with gcloud (human approved): status cleared (no resources, services, ingress); dry-run spec ingress cleared (spec = 3 projects, storage + aiplatform, dry-run). Log scratch/stage4-perimeter-run2.txt. tfvars reset: toggles off, vpc_sc_enforced = false, vpc_sc_operator_ingress = false. Terraform plan after propagation.
- 05:58Z: Terraform removed the 3 toggle policies (plan 0/0/3, only those 3; perimeter: no change, so the gcloud reset matches config). Checks (scratch/stage4-checks-run2.txt): `terraform plan` no changes in infra/ and infra/agents/; 0 lzv-t*/cloudbuild buckets, 0 Cloud Run services, 0 test SAs in all 4 projects; 0 reasoning engines. Snapshot refreshed (diff vs run 1: location list order and etags only; redaction check 0 findings). Environment back to base.

## Run 1 vs run 2

- Final verdicts identical for all 17 tests: PASS T01-T11, T13, T14, T15, T17; FAIL T12; NOT_TESTED T16.
- Run 2 used the scripts as fixed during run 1; no script or expected result changed during run 2. Tests that needed a retry in run 1 (T07, T08, T10, T13 outside-read, T14 a) passed on their first run-2 attempt, so those run-1 retries were spec/script issues, not flaky controls.
- T12 FAIL reproduced: the platform grant of roles/aiplatform.agentDefaultAccess to the project agent principalSet appeared again at agent A deploy.
- Same observations as run 1: T07/T10 errors do not name gcp.restrictNonCmekServices; T10 default staging bucket blocked by gcp.resourceLocations first; T06 enforced by Google default before our policy; Terraform for infra/ cannot plan while the perimeter is enforced (gcloud used for 3b and Stage 4).
- Difference: run 2 Stages 1-4 ran in one sitting (04:37Z-05:58Z) with fixed 15-min waits; run 1 spanned two days and a runtime project replacement.
- Known wording issue: T09 result.json `actual` says "terms named: none" although the error says "public access prevention is enforced" (summary grep only looks for camelCase names; same in run 1). Handle in report wording.
