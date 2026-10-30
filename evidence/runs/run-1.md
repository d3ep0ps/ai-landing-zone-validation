# Run 1

- Date: 2026-10-23. Scripts at commit b2d85bb. Order: tests/RUN-ORDER.md.
- Stage 1 start 2026-10-23T13:38Z. Last org-policy apply ~13:11:28Z: waited ~27 min (docs: up to 15 min).
- T04 inputs (recorded before the run): allowed model = from effective vertexai.allowedModels (gemini-3.5-flash:predict); denied model `T04_DENIED_MODEL=gemini-4-argon` (human choice; official page: GA, publicly available, locations global/us/eu/...); `T04_LOCATION=global`.

| ID | Stage | Verdict | Tier | Evidence | Note |
|---|---|---|---|---|---|
| T01 | 1 | PASS | Enforced | evidence/T01/run-1/ | Key creation denied (FAILED_PRECONDITION, managed constraint); SA cleaned up. Effective-policy read failed (orgpolicy API off in test projects) -> lib fix, see below. |

Environment issue found in T01 (not a test result): `gcloud org-policies describe --project=<test project>` failed with PERMISSION_DENIED "Organization Policy API has not been used in project". Fix (2026-10-23, after T01, before T02): all read-only org-policy calls pass `--billing-project=<seed project>`. T01's verdict does not depend on that read; its evidence is kept as recorded.
| T02 | 1 | PASS | Enforced | evidence/T02/run-1/ | Create and update with --no-invoker-iam-check denied; control deployed. Cleanup failed: `run services delete` prompt needs a terminal. |

T02 cleanup issue: the control service was left behind. Deleted manually by Opus at 2026-10-23 (~13:50Z) with `gcloud run services delete <name> --quiet` after human approval; `run services list` shows no lzv- services. Fix before T03: `cleanup_run_service` in lib.sh (only place `--quiet` is allowed; exception recorded in CLAUDE.md). T02 evidence kept as recorded.
| T03 | 1 | PASS | Enforced | evidence/T03/run-1/ | --ingress=all denied naming run.allowedIngress; internal control deployed; cleanup ok (new helper). |
| T17 | 1 | PASS | Enforced | evidence/T17/run-1/ | Deploy without --binary-authorization refused naming the org policy run.allowedBinaryAuthorizationPolicies (not a BinAuth admission rule); control with =default deployed; cleanup ok. First attempt aborted before any resource (lib name-regex bug), kept in aborted-*/. |
| T04 | 1 | PASS | Enforced | evidence/T04/run-1/ | gemini-4-argon refused HTTP 400 FAILED_PRECONDITION naming constraints/vertexai.allowedModels; control gemini-3.5-flash HTTP 200. No token in evidence (grep ya29. = 0). |
| T08 | 1 | INCONCLUSIVE | Enforced | evidence/T08/run-1/ | Refused HTTP 412 `'us-central1' violates constraint 'constraints/gcp.resourceLocations'`; pre-registered match string had no quotes, so no match. Cleanup ok. Kept as recorded. |

T08 spec issue (human decision 2026-10-23): Cloud Storage quotes the constraint name; docs show it unquoted. Matcher changed to `violates constraint '?constraints/gcp\.resourceLocations'?` (expected text unchanged). Re-run as run-1-r2; both runs reported.
| T08 | 1-r2 | PASS | Enforced | evidence/T08/run-1-r2/ | Same refusal naming constraints/gcp.resourceLocations; matcher accepts quotes. Cleanup ok. |
| T09 | 1 | PASS | Enforced | evidence/T09/run-1/ | allUsers binding refused HTTP 412 "not allowed since public access prevention is enforced" (no constraint ID in text; not DRS). Cleanup ok. |
| T06 before | 1 | (stage recorded) | - | evidence/T06/run-1/stages/ | Effective enforce=true at folder and project before our policy (Google default). |
| T13 setup | 1 | (stage recorded) | - | evidence/T13/run-1/stages/ | Bucket A (data, perimeter) + object, bucket B (outside) created; kept until stage copy. |
| T13 dryrun | 1 | (stage PASS) | - | evidence/T13/run-1/stages/ | Read and copy succeeded in dry-run; dryRun=true entries with NO_MATCHING_ACCESS_LEVEL and RESOURCES_NOT_IN_SAME_SERVICE_PERIMETER (plural observed). Limitation: log query not pinned to this stage; 20 entries include earlier T08/T09 requests. |
| T15 | 1 | PASS | Enforced | evidence/T15/run-1/ | locked=true; raise 1->2 days refused FAILED_PRECONDITION "This bucket is locked. Locked buckets are immutable"; retention still 1. |

Agent A deploy 1 (human apply, ~13:58Z) failed after 7 min: "Reasoning Engine failed to deploy and cannot serve traffic" (no logs in the project; no engine left). Cause (docs, deploy-an-agent): source deploys require class_methods and an entrypoint object that exposes them; fixture had neither (bare ADK Agent). Fixed: `app = AdkApp(agent=root_agent)`, class_methods declared. Fixture issue, not a test result.

## Blocker: runtime project suspended (2026-10-23)

Agent A deploy attempt 3 (~20:41Z) refused: `403 CONSUMER_SUSPENDED` on aiplatform.googleapis.com for prj-lzv-runtime. Google notice: project suspended "because it is associated with repeated Terms of Service violations". No resource was created. Human appealed on 2026-10-23; Google asked to wait 2 days. T11, T12, T14 blocked until resolved. Not a test result.

## Stage 2

- 2026-10-23T21:09Z: toggles applied by Opus at human request (`enable_t05/t06/t07_policy = true` in infra/terraform.tfvars). Targeted apply of the 3 folder policies only (`-target`), because a full plan fails refreshing the suspended runtime project (`google_storage_project_service_account`: 403 "account problem"). Result: 3 added, 0 changed. The API accepted vertexai.configurableComputerUseToolSafetyPolicies (T05 precondition). Earliest test time 21:24Z.
| T05 | 2 | PASS | Configured | evidence/T05/run-1/ | Effective denyAll=true at folder and runtime project (read via seed billing project, works despite suspension). Constraint not in official reference but accepted by the API. |
| T06 | 2 | PASS | Configured | evidence/T06/run-1/ | Effective enforce=true after the folder policy; also true before (Google default), so our folder policy does not change the effective state. |
| T07 | 2 | INCONCLUSIVE | Enforced | evidence/T07/run-1/ | Refused HTTP 412 "A default customer-managed encryption key (CMEK) on the bucket is required by an org policy in effect"; constraint not named. Audit log (audit-log-check.json, read afterwards): code 9, same message, no policyViolationInfo. Cleanup ok. |

T07 spec issue (human decision 2026-10-23): Cloud Storage does not name gcp.restrictNonCmekServices in the error or audit log. Appendix A T07 expected changed to the observed CMEK message, attribution by elimination (only CMEK policy on the folder; T09 created a plain EU bucket in the same project before the toggle). Re-run as run-1-r2. T10 signature also accepts the CMEK message (its expected text "Fails; record exact error" is unchanged).
| T07 | 2 (r2) | PASS | Enforced | evidence/T07/run-1-r2/ | Same CMEK-required refusal under the updated spec; attribution by elimination noted. Cleanup ok. |
| T10 | 2 | INCONCLUSIVE | Enforced | evidence/T10/run-1/ | `gcloud builds submit` failed `HTTPError 412: 'us' violates constraint 'constraints/gcp.resourceLocations'`: the default staging bucket is created in `us`, so the location policy blocks it before CMEK is evaluated. No bucket created. gcloud 583.0.0. |

T10 finding (human decision 2026-10-23): the trap (plain builds submit fails) is real here, but caused by gcp.resourceLocations, not CMEK. Run 1 kept INCONCLUSIVE. Added isolated attempt for run-1-r2: regional user-owned staging bucket in europe-west1, so only CMEK can block.
| T10 | 2 (r2) | PASS | Enforced | evidence/T10/run-1-r2/ | Default bucket: blocked by gcp.resourceLocations (us). Regional user-owned bucket: refused HTTP 412 CMEK-required by org policy. No bucket created; cleanup check: none new. |

## Replacement runtime project (2026-10-24)

- Human chose not to wait for the appeal. Analysis of possible causes: notes/tos-suspension-analysis.md (audit log shows no unknown principal).
- Human deleted PROJECT_1 (soft delete). Opus removed module.prj_runtime from Terraform state (backup scratch/tfstate-before-runtime-rm.json), renamed the project to prj-lzv-runtime2, reviewed the plan (43 add: project, 12 APIs, service-agent grants only; perimeter dry-run spec swaps the project number) and applied at the human's request: complete 2026-10-24T06:05:43Z.
- Effective policies on the new project checked read-only: allowedModels = gemini-3.5-flash:predict, key creation blocked, computer-use denyAll, CMEK deny storage. Snapshot refreshed (redaction check: 0 findings).
- Agent fixture: tool now fetches a fixed URL (https://example.com), no caller-chosen target.
- Runtime-project tests (T01, T04, T05) re-run in the new project as run-1-r2; run-1 results (old project) kept.
| T01 | 1 (r2, runtime2) | PASS | Enforced | evidence/T01/run-1-r2/ | Effective policy enforce=true read ok; key creation denied; SA deleted (post-check describe: PERMISSION_DENIED, IAM convention for a missing SA). |
| T05 | 2 (r2, runtime2) | PASS | Configured | evidence/T05/run-1-r2/ | denyAll at folder and runtime2. |
| T04 | 1 (r2, runtime2) | PASS | Enforced | evidence/T04/run-1-r2/ | gemini-4-argon refused HTTP 400 naming constraints/vertexai.allowedModels; control gemini-3.5-flash HTTP 200. No token in evidence. |
- 2026-10-24T06:17Z: agent A deployed in runtime2 by human apply (1 add, 4m58s). Fixture works: AdkApp entrypoint + class_methods. Agents are paid: destroy in Stage 4.
| T11 | 1 (runtime2) | PASS | Enforced | evidence/T11/run-1/ | Terraform output and REST spec.effectiveIdentity identical: principal://agents.global.org-<ORG>.../reasoningEngines/<ENGINE>; no SA email. Identity type = module default. |
| T12 | 1 (runtime2) | FAIL | Enforced | evidence/T12/run-1/ | Fleet grant: roles/aiplatform.agentDefaultAccess (includes aiplatform.endpoints.predict) on principalSet of all agents in the runtime project, granted by the platform at first deploy (our Terraform grants none). None at folder/org. Analyzer: accepted principal://, 0 inference paths, but positive control also 0 results, so analyzer evidence is not validated; verdict rests on direct policy inspection. |

T12 decision (human, 2026-10-24): FAIL recorded as a finding about platform defaults; no spec change; positive-control failure goes to limitations.
| T14 a | 1 | INCONCLUSIVE (stage) | - | evidence/T14/run-1/stages/ | Query HTTP 200, but the agent's model call got 404 "publisher model gemini-3.5-flash not found": the runtime sets the model location to the agent region europe-west1, where the model is not served (model page: global, us, eu, europe-west2/3). Tool never called. Fixture issue. |

T14 fixture fix (2026-10-24): agent model calls go to `global` via LZV_MODEL_LOCATION (agent stays in europe-west1). Limitation: global endpoint processing may be outside the EU. In-place update of agent A (same engine and identity, so T11/T12 evidence stays valid). T14 re-run as run-1-r2 (stage a, later stage b).
| T14 a | 1-r2 | INCONCLUSIVE (stage) | - | evidence/T14/run-1-r2/stages/ | Agent worked: raw stream shows fetch_url call and function_response {status: 200, error: null}. Script parser read only `data: ` SSE lines; the stream is plain newline-delimited JSON, so it counted 0. Script bug. |

T14 parser fix (2026-10-24): accept JSON lines with or without `data: ` prefix; checked offline against the r2 stream (status=200). Re-run as run-1-r3; stage b must also use run-1-r3.
| T14 a | 1-r3 | PASS (stage) | - | evidence/T14/run-1-r3/stages/ | Agent A (deployed before enforcement) fetched https://example.com: function_response status 200. Stage 1 complete. |

## Stage 3a

- 2026-10-24T06:27Z: perimeter enforced by human apply (vpc_sc_enforced = true; status = 3 projects, storage + aiplatform restricted, no ingress). Earliest test time +15 min.
| T13 outside-read | 1 | INCONCLUSIVE (stage) | - | evidence/T13/run-1/stages/ | Read refused HTTP 403 "Request is prohibited by organization's policy" with vpcServiceControlsUniqueIdentifier. Enforced-mode log entry exists (received 06:43:47, violationReason NO_MATCHING_ACCESS_LEVEL) but has no dryRun field; the script filter `dryRun!=true` does not match a missing field. Script bug. |

T13 fix (2026-10-24): filter `NOT protoPayload.metadata.dryRun=true` (verified read-only: matches the entry). Stage retries allowed as STAGE-rN (own stage file); final merge uses the latest attempt and lists earlier ones. Re-run as outside-read-r2 in run-1.
| T13 outside-read | 1 (r2) | PASS (stage) | - | evidence/T13/run-1/stages/ | Read refused (403, VPC-SC); enforced-mode log violationReason NO_MATCHING_ACCESS_LEVEL. Stage 3a complete. |

## Stage 3b

- 2026-10-24T06:54Z: operator ingress rule (operator user, any source, storage + aiplatform, resources *) added to perimeter lzv_ai status and dry-run spec with `gcloud access-context-manager perimeters [dry-run] update --set-ingress-policies` (human approved). Terraform could not plan: with the perimeter enforced and no ingress, the project module's storage service-account reads are refused by VPC-SC, even with -target/-refresh=false. The same rule is in infra/vpc-sc.tf (vpc_sc_operator_ingress = true) so Terraform matches once it can read again.
- 07:10Z: Terraform drift check still refused after 16 min. Audit log of one refused call: egress violation RESOURCES_NOT_IN_SAME_SERVICE_PERIMETER, source = perimeter project, target = the quota project (seed, outside the perimeter), permission serviceusage.services.use. Cause: Terraform (ADC) and gcloud send the seed project as quota project; the perimeter treats that as egress. The ingress rule itself works.
- Consequences and fixes (before T13 copy): T13 copy and the perimeter-bucket cleanup bill the data project (`--billing-project`), and the copy verdict additionally requires the egress target to be the outside project, so a quota-project refusal cannot give a false PASS. Limitation: the T13 dry-run RESOURCES_NOT_IN_SAME_SERVICE_PERIMETER entries may include quota-project egress. Terraform plans of infra/ stay blocked while the perimeter is enforced (Stage 4: clear enforcement with gcloud first).
| T13 | 3b | PASS | Enforced | evidence/T13/run-1/ | copy refused: egress RESOURCES_NOT_IN_SAME_SERVICE_PERIMETER, target = outside project (billed inside the perimeter). Merged with setup, dryrun, outside-read (r1 INCONCLUSIVE filter bug, r2 PASS). Buckets deleted (404 on check). |
- 2026-10-24T07:20Z: agent B deployed (human apply) inside the enforced perimeter; agents provider billed the runtime project (seed quota project is refused as egress).
| T14 | 3b (r3) | PASS | Enforced | evidence/T14/run-1-r3/ | A (deployed before enforcement): tool status 200. B (deployed inside the enforced perimeter): tool error `URLError: [Errno 101] Network is unreachable`; the query itself was allowed (HTTP 200, no VPC-SC error). |

## Run 1 complete (2026-10-24)

All 17 tests have a run-1 result: T01-T11, T13-T15, T17 PASS (several after documented retries); T12 FAIL (platform fleet grant, finding); T16 NOT_TESTED (deferred, script exists, not run: records NOT_TESTED when run).
| T16 | - | NOT_TESTED | Documented | evidence/T16/run-1/ | Deferred to v1.1. |
- 2026-10-24T07:23Z: Stage 4: agents A and B destroyed (reviewed destroy plan, 2 destroyed); API list shows 0 reasoning engines.
- 2026-10-24T07:26Z: Stage 4 perimeter reset with gcloud (human approved): enforced status cleared (no resources, services, ingress); dry-run spec ingress cleared (spec = 3 projects, storage + aiplatform). tfvars reset: toggles off, vpc_sc_enforced = false, vpc_sc_operator_ingress = false. Terraform plan to follow after propagation.
- 2026-10-24: Stage 4 complete. Terraform removed the 3 toggle policies (0 add, 0 change, 3 destroy). Checks: no lzv-t* or cloudbuild buckets, no lzv- Cloud Run services, no test SAs in any of the 4 projects; `terraform plan` shows no changes in infra/ and infra/agents/; snapshot refreshed (redaction check 0 findings). Environment is back to base for run 2. Locked log bucket remains (irreversible, empty).
