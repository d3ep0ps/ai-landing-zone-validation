# Run 4 (v1.1, first run) log

Scripts at commit 8ce113f unless noted. Expected results: EXECUTION-PLAN.md Appendix D, D3 (locked at e72476e).

## Stage 1 (enable_t07_policy=true, enable_dc3_build_bucket=true; applied 2026-10-25, waited 15 min)

| Test | Verdict | Note |
|---|---|---|
| T20 | PASS (Enforced) | No-CMEK bucket refused (HTTP 412); CMEK control bucket created and deleted. No Policy Denied audit entry naming the constraint within 5 polls: attribution by elimination. |
| T21 | INCONCLUSIVE (Enforced) | Plain build refused by `gcp.resourceLocations` (`us`), as v1 T10. CMEK-bucket build failed with 403: the build ran as the mcp compute default SA, which had no access to the CMEK bucket. Fixture gap, not a CMEK result. |

Fixture deviation (T21): DC3 granted only the mcp legacy Cloud Build SA (Opus review, because the compute API was not in the project's services list). The provider had enabled the compute API in the mcp project during the base apply (default network delete), so the compute default SA exists and Cloud Build uses it. Fix: `dc3_build_service_accounts` = mcp compute default SA (tfvars only, no code change); re-run as run-4-r2 with the same expected result.
| T21 (run-4-r2) | INCONCLUSIVE (Enforced) | After objectAdmin for the mcp compute SA: source upload worked, then FAILED_PRECONDITION "invalid bucket ...; service account ... does not have access to the bucket". Plain build again refused by `gcp.resourceLocations`. Cloud Build docs: a build SA other than the same-project legacy SA needs roles/storage.admin on the bucket. Fix: DC3 grants roles/storage.admin on the build bucket only; re-run as run-4-r3, same expected result. |
| T21 (run-4-r3) | PASS (Enforced) | Script commit b09709b. Build through the CMEK bucket (`--gcs-source-staging-dir`, `--gcs-log-dir`, regional) succeeded; plain build refused by `gcp.resourceLocations` (`us`). Cleanup: source and log objects deleted, no new cloudbuild buckets (checked again by Opus: mcp project has no buckets, CMEK bucket empty). |

Finding (DC3 design): a CMEK build bucket in another project needs `roles/storage.admin` on that bucket for the build service account (here the compute default SA, because the compute API is enabled in the build project); object-level roles are not enough. The project factory must grant it.

## Stage 2 (enable_t07_policy=false, enable_dc4_sink=true; applied 2026-10-25, waited 15 min)

| Test | Verdict | Note |
|---|---|---|
| T24 | PASS (Enforced) | Folder sink wrote to the locked bucket: the probe service account's Admin Activity entry appeared after 2 polls (about 2 min). Retention raise 1 -> 2 days refused: "FAILED_PRECONDITION: This bucket is locked. Locked buckets are immutable"; retentionDays still 1. Probe SA deleted. Closes the v1 C10 gap (no logs had been routed to the locked bucket). |

## Stage 3 (enable_t25_binauthz=true; applied 2026-10-25 in three steps)

- Step 1 (plan-v11-stage3): 5 of 8 created (APIs, KMS key ring and signing key, signer grant), then "Error 403: Container Analysis API has not been used in project <seed project>": the note call is billed to Terraform's quota project (seed), outside the test folder. Human approved enabling `containeranalysis.googleapis.com` in the seed project.
- Step 2 (plan-v11-stage3b): note and attestor created; policy failed with "Provider produced inconsistent final plan ... require_attestations_by: was null, but now cty.SetVal([... attestors/lzv-attestor])" (Google provider bug: the set is not shown as unknown at plan time).
- Step 3 (plan-v11-stage3c, planned after the attestor existed): policy created. Live policy (read back): REQUIRE_ATTESTATION, ENFORCED_BLOCK_AND_AUDIT_LOG, attestor `lzv-attestor`; attestor public key ID in the `//cloudkms.googleapis.com/v1/...` form.
- Operating note for DC3/T25 designs: create attestors in a separate apply before the policy that references them.

| Test | Verdict | Note |
|---|---|---|
| T25 | PASS (Enforced) | Script commit b09709b. Unattested digest refused: "Container image '...' is not authorized by policy." Same digest after `gcloud beta container binauthz attestations sign-and-create`: deployed. Cloud Run service deleted (cleanup_run_service). Leftovers: the temporary Artifact Registry repository (delete prompts; no `--quiet`; human step) and the build source and log objects in the CMEK bucket (deleted by Opus by exact name, scratch/t25-run4-manual-cleanup.txt). T25.sh cleanup changed before run-5 (object cleanup as T21; repository delete printed as a human step); expected text unchanged. |

Observation: the mcp compute default service account holds `roles/editor` on the project (Google's automatic grant to default service accounts); T25 and T21 builds ran as this account. The test folder has no `iam.automaticIamGrantsForDefaultServiceAccounts` policy. Not a test in v1.1; candidate for the design (DC backlog).

## Stage 4 (no apply; T25 stays on, see tests/RUN-ORDER-v11.md)

| Test | Verdict | Note |
|---|---|---|
| T19 `before` | stage PASS | First attempt aborted on the agents output guard before any IAM read (infra/agents never applied in v1.1, output `{}`); kept in evidence/T19/aborted-run-4-before/ with a hand-added note. Guard fixed (commit after b09709b); re-run wrote 8 snapshots. Runtime project has no `principalSet://agents...` binding before any agent is deployed. |

## Stage 5 (infra/agents deploy_agent_a=true; applied 2026-10-25, waited 5 min)

| Test | Verdict | Note |
|---|---|---|
| T19 `after` / final | PASS (Configured) | Script commit dd86980. Deploying one agent added exactly one binding: `roles/aiplatform.agentDefaultAccess` on the runtime project's agent principalSet (absent in the `before` snapshot). No other binding added or removed at the three projects and two folders; no deny policies. Confirms v1 T12: the platform makes this grant at deploy time. |

## Stage 6 (infra/agents deploy_agent_b=true; applied 2026-10-25)

| Test | Verdict | Note |
|---|---|---|
| T18 `pre` | stage PASS | Script commit dd86980. No deny policy present. Agent B then agent A queried once each via streamQuery: HTTP 200; each made a `fetch_url` call (status 200) and a model text part from `gemini-3.5-flash` (checked by Opus in output.txt). Both agents can call the model before DC1. |

## Stage 7 (enable_dc1_deny=true, exception = agent A; applied 2026-10-25 after the human granted themselves roles/iam.denyAdmin at org level)

| Test | Verdict | Note |
|---|---|---|
| T18 `post` / final | PASS (Enforced) | First post attempt aborted on the deny-policy list parser (gcloud returns `{"policies": [...]}` without rules) before any agent query; hand note in output.txt; parser fixed (5bae843). Re-run: policy listed, age 777 s, exception = agent A. Agent B's model call refused: "Permission 'aiplatform.endpoints.predict' denied on resource '//aiplatform.googleapis.com/projects/.../locations/global/publishers/google/models/gemini-3.5-flash' due to an IAM deny policy." Agent A's identical query answered. |

Observation: the denial text names the IAM deny policy as the cause (the v1.1 doc check expected a generic PERMISSION_DENIED). The pre-registered signature (PERMISSION_DENIED) is met; the script's "generic text" limitation note is wrong for this run and is corrected here, not in the evidence.
Operator prerequisite found: creating a deny policy needs roles/iam.denyAdmin; Security Admin has only iam.denypolicies.list. Granted by hand at org level; remove at teardown.

## Stage 8 (deny off; agents A and B destroyed; runtime removed from the dry-run spec by gcloud, human approved; fresh agent A deployed with runtime in no perimeter)

| Test | Verdict | Note |
|---|---|---|
| T23 `pre` | stage PASS | Fresh agent A (deployed while the runtime project was in neither spec nor status) fetched https://example.com: tool status 200. The earlier agent A (deployed while runtime was in the dry-run spec) was destroyed so the deploy-order design matches T14R. |

Before stage 9 (found by Opus, no run affected): (1) the tooling quota project must have the APIs Terraform calls enabled (data project lacked orgpolicy, accesscontextmanager, cloudbilling, containeranalysis) - DC2 now enables a list when `tooling_quota_project` is set; (2) T22 passed the quota project only by env vars, but the providers set `billing_project = var.quota_project` explicitly and terraform.tfvars outranks TF_VAR_*, so T22 now passes `-var quota_project=...`. Expected text unchanged.

## Stage 9 (tooling_quota_project = data project; dry-run spec back to 3 projects; waited 15 min)

| Test | Verdict | Note |
|---|---|---|
| T22 `dryrun` (run-4) | stage FAIL (measurement fault) | Script commit ede24cd. Recorded: old quota project=8, tooling quota project=16. Opus read the same entries (scratch/t22-viol-all.json, 60 min window): every egress violation (`RESOURCES_NOT_IN_SAME_SERVICE_PERIMETER`) targets the seed project; none targets the data project. The 16 were ingress entries (`NO_MATCHING_ACCESS_LEVEL`) where the data project was the resource read from the operator laptop, plus egress entries whose source (not target) was the data project. The script matched the project anywhere in the egress/ingress fields. Matcher fixed to egress `targetResource` only; re-run as run-4-r2; expected text unchanged. The run-4 stage record is kept. |

Note for T22 `enforced`: the same entries show that, once enforced, operator calls from the laptop into the perimeter are ingress violations (`NO_MATCHING_ACCESS_LEVEL`) regardless of the quota project. Stage 10 therefore needs `vpc_sc_operator_ingress = true` (as v1 stage 3b) so that T22 measures the quota-project egress, not operator ingress.

## Stage 10 (perimeter enforced; operator ingress; agent ingress [A], then agent B deployed after 15 min of enforcement, then [A, B])

- 10a applied (human). 10b: first apply failed on expired reauth (nothing created), re-planned, agent B deployed (5m59s).
- 10c planning, observed before T22 `enforced` (operations evidence, scratch/v11-plan-stage10c.txt): with the perimeter enforced, `terraform plan` with the in-perimeter data project as quota project failed on `module.prj_outside.data.google_storage_project_service_account.gcs_sa`: "Error 403: Request is prohibited by organization's policy. vpcServiceControlsUniqueIdentifier: ...". The outside project's lookup billed to an in-perimeter project is refused, the mirror image of F5 (seed quota project refused for in-perimeter resources). A stack that manages projects on both sides of the perimeter cannot use one quota project. 10c was planned with `-target=module.vpc_sc` and the data quota project (perimeter only).

| Test | Verdict | Note |
|---|---|---|
| T22 `enforced` (run-4-r2) | INCONCLUSIVE (recorded; script commit af47222) | Plan exit 1, gcloud read exit 0, enforced egress violations targeting the tooling quota project = 0. The only plan error is `module.prj_outside.data.google_storage_project_service_account.gcs_sa`: "Error 403: Request is prohibited by organization's policy. vpcServiceControlsUniqueIdentifier: ..." with reason `SECURITY_POLICY_VIOLATED`. This is a VPC-SC refusal (the stage 10c mirror finding), but the script's signature (`VPC Service Controls|VPC_SERVICE_CONTROLS`) did not match it, so the stage was scored INCONCLUSIVE instead of FAIL. Reading of the evidence: the expected result ("both succeed") was not met for the plan; in-perimeter resources are fine with the tooling quota project, the outside-project lookup is refused. Finding: DC2 step 1 removes F5 for in-perimeter resources but a single quota project cannot serve a stack that spans the perimeter boundary. Signature widened before run-5 (expected text unchanged); not re-run in run-4 because the dryrun stage cannot be repeated while enforced. |
| T23 `post` (run-4) | PASS | Agent A (approved ingress identity) tool fetch status 200 before and after; agent B tool fetch failed with "URLError: <urlopen error [Errno 101] Network is unreachable>". |

## Stage 11 (T16) — stopped before apply, 2026-10-26

- Targeted plan (`-target` SWP blocks, data quota project) failed on `module.prj_runtime.data.google_storage_project_service_account.gcs_sa`: "Error 403: There is an account problem for the requested project., forbidden" (scratch/v11-plan-stage11.txt).
- Cause found: the runtime project is suspended as an API consumer. `gcloud logging read --project=<runtime>`: "Consumer 'projects/<runtime>' has been suspended", reason `CONSUMER_SUSPENDED` (scratch/stage11-vpcsc-30m.err). The project still shows ACTIVE and billing enabled; Storage and Logging calls fail. Data, mcp and outside projects work normally.
- The suspension happened after T23 `post` (last successful runtime call, 2026-10-25 ~21:15Z). Reason not known yet: check the notice to project owners or the console.
- Nothing was applied. `swp_enabled` set back to false. T16 not run.
- 2026-10-26: the operator submitted an appeal for the runtime project. T16 and run-5 wait for the outcome.
- 2026-10-26: Google reinstated the runtime project after the appeal (reported by the human); no reason given. Stage 11 resumes.

## Stage 11 (T16), resumed 2026-10-26 after reinstatement

- Targeted plan (SWP blocks, data quota project): 16 add. SWP outputs got `depends_on` on the SWP modules so the targeted plan sets them (b138546). Applied by the human. Gateway `lzv-swp` createTime 2026-10-26T20:23:52Z (billing start). Enabling the Compute API in the runtime project is part of this apply.

| Test | Verdict | Note |
|---|---|---|
| T16 (run-4) | PASS | Script commit b138546. Allowed host via proxy: 200; non-allowed host: 403 on CONNECT, `gateway_requests` DENIED entry present; proxy bypassed: connection timed out (not DNS). Cleanup: the three job deletes need a terminal (no `--quiet`), so they are a human step. |
- T16 cleanup: the three jobs were deleted by the human in their own terminal (the `!` prompt cannot answer the confirmation). Destroy apply (human, 2026-10-26 ~20:30Z): gateway, policy, rule, routes, proxy-only subnet and firewall rules destroyed; gateway list empty, no routers left by 20:35Z (about 11 gateway-minutes from createTime 20:23:52Z). The job subnet `lzv-swp-job` and the VPC were not destroyed: "The subnetwork resource ... is already being used by ... addresses/serverless-ipv4-cloudrun-..." (a Cloud Run Direct VPC egress address, released by Google after the jobs are gone). Re-plan the destroy later; subnet and VPC are free.
