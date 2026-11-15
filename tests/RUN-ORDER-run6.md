# Run-6 order: all tests in one sequence (DRAFT)

Status: draft, 2026-10-27 (stage 1-0 split into 1-0a/1-0b and T25 moved out of 1-0 before the run: `enable_t25_binauthz` has no attestor-only part, so turning it on in 1-0 would also turn on the Binary Authorization policy and block T17 in 1-1), updated after the v2 doc check (Appendix E, "E2 result"). The v1 and v1.1 parts use existing scripts and expected results and are final as an order. The v2 rows (T27–T39b, without T31 and T35) become tests only after the human approves E3. Nothing has been applied.

Requested by the human on 2026-10-27: run every test once more (v1 T01–T17 and T14R, v1.1 T16 and T18–T25, and v2 as far as possible) in a sequence that keeps the 15-minute propagation waits to a minimum.

Run ID: `run-6` for every test; retries `run-6-rN`. Expected results are unchanged for v1 and v1.1 (scripts' `header` text as committed). Rules from [RUN-ORDER-v11-run5.md](RUN-ORDER-v11-run5.md) apply: the human applies every plan; pacing (one agent deploy at a time, 30 minutes apart, no rapid retries, stop on `CONSUMER_SUSPENDED`); paid resources created and destroyed the same day; both logins fresh before each batch.

## How the waits are kept down

1. **One apply per state change.** Every change a stage needs goes into one apply (several toggles at once), so one wait covers all of them.
2. **Group tests by the state they need.** All tests that need the same folder-policy, org-policy and perimeter state run in the same stage.
3. **Use the wait.** During a wait, run only tests on services that the pending change does not touch (stated per stage). A test that the pending change could affect never runs during its wait: half-propagated policies give flaky results.
4. **Agents are reused.** Agent A (deployed before enforcement) serves T11, T12, T14 `a`, T14R, T19, T23 and T18; agent B (deployed after enforcement) serves T14 `b`, T23 and T18. Only v2 adds agents.
5. **Deny-policy wait is 10 minutes**, org-policy and perimeter waits 15 minutes (as before).

Estimated waits: day 1 about 30 min (2 waits), day 2 about 70 min (5 waits; the first is used for T19 `before`), day 3 about 10 min (one deny-policy wait, provisional; T37 moved to day 2, so day 2 has one more 10-minute wait). For comparison, run-5 alone (v1.1 tests only) had 7 waits, about 100 min.

## Before day 1 (fixture work, no tests)

| # | Item | Why |
|---|---|---|
| P1 | Clean up the SWP leftovers (subnet `lzv-swp-job`, VPC, 4 API entries) once the serverless address is gone; or keep them and let day 2 reuse them | v1.1 leftover |
| P2 | Key rings (path A chosen by Opus 2026-10-27, needs the human: before 2026-11-26, restore and enable version 1 of both keys with the four `gcloud kms keys versions` commands in infra/README.md "v2"; then `p2_import_existing_kms=true` imports rings and keys with no other change; restore and enable done 2026-10-27, both version 1 ENABLED). Background: `lzv-build-keyring` (runtime) and `lzv-binauthz-keyring` (mcp) still exist but are out of Terraform state (they cannot be deleted). Before T21 and T25 can be enabled again, add `import` blocks (or `terraform import`) for both rings, and import or rename the keys (keys also cannot be deleted; destroyed keys keep their name). `infra-writer` drafts; Opus reviews | Otherwise the apply fails with "already exists" |
| P3 | T19 cannot repeat "binding added at deploy" in the runtime project: the binding is already there (F14). Human decision: (a) accept added=0 again, or (b) a fresh runtime project for day 2 (new project, so suspension risk as before). Human decision 2026-10-27: (a), accept added=0 and record it | T19 / C13 |
| P4 | `T04_DENIED_MODEL` set in the run file before the run. Done 2026-10-27: `gemini-4-argon` (as runs 1, 2, 5), recorded in evidence/runs/run-6.md | T04 precondition |
| P6 | `terraform init` in `infra/`, `infra-split/inside` and `infra-split/outside` (T39 checks for `.terraform`). T39b paired control needs `T39B_OTHER_SA`: a service account the operator may impersonate and that is not in the egress rule (no keys; human creates it or drops the control, which makes T39b INCONCLUSIVE). Done 2026-10-27: all three roots initialised; `T39B_OTHER_SA=SA_11@PROJECT.iam.gserviceaccount.com` (data project, no keys), roles: storage.bucketViewer on data, serviceUsageConsumer on seed, operator TokenCreator on the SA (granted by human, verified; impersonated read works with the perimeter in dry-run) | T39 / T39b |
| P5 | v2 fixtures after E2: Model Armor API and templates, PSC-I network attachment, Gemini Enterprise trial, split Terraform roots for T39 | v2 |

## Day 1: policies, Model Armor, organization scope (no agents)

Perimeter in dry-run with the runtime project in the spec (current base).

| Stage | Apply before (human), then wait | Tests (`RUN_ID=run-6`) | During the wait |
|---|---|---|---|
| 1-0a | Project scope, one apply: `p2_import_existing_kms=true` with `enable_dc3_build_bucket=true` (imports the DC3 ring and key), `enable_dc4_sink=true`, `enable_v2_model_armor=true` (API and T28 template; `modelarmor.googleapis.com` is already on the seed project). The plan also destroys the 6 SWP leftovers (P1: the serverless address is gone, checked 2026-10-27). No wait | — | — |
| 1-0b | Org scope, alone (README: org-scope toggles one at a time): `t36_mode="dryrun"` (custom constraint + dry-run policy; it propagates while 1-1 runs, and T36 `dryrun` needs T07 off). No wait before 1-1: a dry-run org policy blocks nothing | — | — |
| 1-1 | none (base state; T05/T06/T07 toggles off) | T01, T02, T03, T17, T04, T08, T09, T06 `before`, T13 `setup`, T13 `dryrun`, T15, T24; v2: T28 (Model Armor screening API); last, at least 15 min after 1-0: T36 `dryrun` (polls up to 30 min for the dry-run audit entry) | — |
| 1-2 | One apply: `enable_t05_policy=true`, `enable_t06_policy=true`, `enable_t07_policy=true`; v2: `enable_v2_ma_folder_floor=true` (T27), `enable_v2_ma_vertex=true` (T29, project floor in the runtime project). Wait 15 | T05, T06 `after`, T07, T10, T20, T21; v2: T27, T29 | Nothing that creates buckets or Cloud Build runs (T07 pending). T15/T24 can move here if 1-1 runs late |
| 1-3a | Project/folder scope, one targeted apply: T05/T06/T07 toggles off (`-target=module.folder_root`); `v2_ma_floor_enforce = { folder = false }` (`-target=google_model_armor_floorsetting.v2_folder`; the folder floor stays but stops enforcing, otherwise it wins over the org floor); T25 first part with `enable_t25_binauthz=true`: `-target=google_project_service.t25 -target=module.t25_kms -target=module.t25_binauthz[0].google_container_analysis_note.notes -target=module.t25_binauthz[0].google_binary_authorization_attestor.attestors` (imports the T25 ring and key; the policy is not created, F12). No wait of its own | — | — |
| 1-3b | Org scope, alone: `t36_mode="enforce"` (exception: outside project) | — | — |
| 1-3c | Org scope, alone: `enable_v2_ma_org_floor=true`. Wait 15 after this apply (covers 1-3a and 1-3b) | v2: T36 `enforce`, T38 (data project, no project floor) | — |

While T36 is enforced, every new bucket in the organization needs the label `lzv-org-test`, including Terraform-created ones: no bucket-creating apply or test runs between 1-3 and the T36 rollback.
| 1-4 | Remove the T36 org policy first if its constraint could touch T25 (the build writes to the DC3 bucket). `enable_t25_binauthz=true` (policy, second apply). Binary Authorization is not an org policy: no 15-minute wait (run-4/5 had one by accident of order); if the first attempt is refused for the wrong reason, wait and retry once | T25; human deletes the T25 repository | — |
| 1-5 | Day-1 reset: `enable_t25_binauthz=false` (check `ALWAYS_ALLOW`), `t36_mode="off"` (rollback commands in infra/README.md "v2"), floors: each level `v2_ma_floor_enforce.<level>=false`, apply, then the floor toggles off, `enable_dc3_build_bucket=false`, `enable_dc4_sink=false` | — | — |

Notes: T17 runs before T25 is on (its positive control is refused while T25 is on). T08, T09 and T13 `setup` run before T07 is on (T07 refuses their plain buckets). T20 and T07 use the same toggle and run in the same stage. T10 and T21 need T07 on.

## Day 2: perimeter, agents, deny policy, egress (paid: agents, Secure Web Proxy)

| Stage | Apply before (human), then wait | Tests | During the wait |
|---|---|---|---|
| 2-0 | gcloud (human approved): remove the runtime project from the dry-run spec. Wait 15 | — | T19 `before` (IAM reads only; the perimeter does not cover Resource Manager) |
| 2-1 | infra/agents: `deploy_agent_a=true` | T19 `after`, T11, T12, T14 `a`, T14R `pre`, T23 `pre` | — |
| 2-2 | infra (full plan, perimeter in dry-run): runtime back in the spec; `tooling_quota_project=<data>`. Wait 15 | T22 `dryrun` | — |
| 2-3 | infra, targeted at `module.vpc_sc`: `vpc_sc_enforced=true`, no ingress rules. Wait 15 | T13 `outside-read` (T14R `post` moved to 2-4a, run-6 day 2: it needs operator ingress) | — |
| 2-4a | gcloud (human; Terraform plans are refused before operator ingress, as in runs 1–3): status and dry-run spec get the operator ingress (operator + `serviceAccount:lzv-t39b-control@…`) and the T39b egress rule (storage, 2 methods from the dry-run violations, seed project). Wait 15 | T14R `post` (operator ingress, no agent rule: agent A refused) | — |
| 2-4b | gcloud (human): ingress set to operator + agents [A] on status and spec. Wait 15. Then a Terraform plan (data quota project) as the drift check: no changes expected | T23 `post` comes in 2-5 | T13 `copy`, T22 `enforced`, T39 (split stacks), T39b (agent ingress does not affect them) |
| 2-5 | infra/agents: `deploy_agent_b=true` (at least 30 min after A) | T14 `b`, T23 `post`, T18 `pre` | — |
| 2-6 | infra, targeted: `enable_dc1_deny=true`, exception `[A]`. Wait 10 | T18 `post` | v2: T39 if not done in 2-4 (Terraform plans; the deny policy does not affect them) |
| 2-6b | v2, one targeted apply: project deny removed, folder deny for `principalSet://agents.global.org-ORG_ID.system.id.goog/*` with exception `[A]` added (T37). Wait 10 | T37 | — |
| 2-7 | infra, targeted: `swp_enabled=true`; v2: PSC-I network attachment (P5) | T16; human deletes the 3 jobs. v2: deploy agent C with PSC-I (at least 30 min after B), then T33, T34 | — |
| 2-8 | Day-2 reset: agent C destroyed, `swp_enabled=false` (gateway gone), deny policies off (project and folder), agents A and B destroyed, perimeter back to dry-run with no ingress, `tooling_quota_project=null`; untargeted plan (only the SWP subnet leftover expected) | — | — |

Deviation from run-4/5 (record it in the run log): stage 2-5 keeps agent ingress at `[A]` only. Agent B is deployed inside the enforced perimeter and in v1 (T14 `b`) its own calls worked without an ingress rule, so the `[A, B]` step and its 15-minute wait are dropped. If T23 `post` or T18 `pre` shows agent B's API calls refused, stop: add `[A, B]` (as run-5 stage 6c), wait 15, and re-run as `run-6-r2`.

T14R and T23 share one agent A: T14R `post` needs enforcement without the agent ingress rule (A refused); stage 2-4 then adds the rule, and T23 `post` needs A working again. T14 `a` is the same deploy-before-enforcement observation as T23 `pre`.

## Day 3: Agent Gateway (provisional; docs list europe-west1 as supported, checked 2026-10-27; the gateway create in 3-0 is the real check)

| Stage | Apply before | Tests |
|---|---|---|
| 3-0 | Preflight: Agent Gateway region list (the test folder allows EU locations only). If no EU region: area B is NOT_TESTED with that reason, and day 3 is not needed. Otherwise: Agent Registry, MCP fixture (registered tool, unregistered tool, injection response), gateway with the Model Armor extension, agent G behind it; project deny policy (T18 form) with G as exception. Wait 10 after the deny policy | — |
| 3-0b | infra/agents: `deploy_agent_b=true` again, at least 30 min after agent G (T31b needs a non-approved agent; B was destroyed at the end of day 2 under the same-day rule). B is not an exception in the deny policy | — |
| 3-1 | none (about 4 min after the last registry change) | T30, T31 (= E3 row T31b), T32 |
| 3-2 | Final reset: `tests/fixtures/gateway/teardown.sh run`, deny policy removed, agents G and B destroyed; organization back to its baseline (only `iam.allowedPolicyMemberDomains`); untargeted plan shows no drift | — |

The Gemini Enterprise trial is not needed (E2 result). Agent deploys over the three days: A, B, C (day 2; C with PSC-I), G and B again (day 3). Day 3 also needs networkservices, networksecurity, agentregistry, iap and modelarmor enabled on the seed project (quota project), by the human.

## After run-6

- v2 tests need a second run (E5 item 4): `run-7` uses the same order, on another day.
- Teardown: ~~remove the operator's org-level `roles/modelarmor.floorSettingsAdmin` (granted 2026-10-27) and `roles/iam.denyAdmin`~~. Human decision 2026-10-28: both org-level roles are kept, and the T39b control service account is kept (no keys), for run-7.
- Redact and commit the evidence, update the reports (v1, v1.1 and v2 sections), then the public copy.

## Before run 7: gateway changes (human decision 2026-10-28)

Run 7 changes the area-B setup (fixtures only; T30-T32 expected results unchanged). Report T30-T32 as "with agent token binding turned off, IAP policy V2".

1. **Agent G token binding off** (`infra/agents` var `agent_g_caa_token_binding_opt_out`, default true): sets `GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=False`, as in Google's gateway deploy samples. Reason: run-6 401 (F16; `notes/doc-verification-v2-B-401.md`).
2. **Agent G packages pinned** (`tests/fixtures/gateway/agent_g/requirements.txt`: aiplatform 2.6.0, adk 2.13.0). Rebuild with `tests/fixtures/gateway/agent_g/build.sh` before the deploy.
3. **IAP policy V2** (`infra` var `v2_gateway_iap_policy_version`, default "V2"): the V1 registry grant is replaced by access policy `lzv-gw-egress` and its project binding (`notes/doc-verification-v2-B-iapv2.md`). Human steps before the day-3 apply:
   - Org policy: checked 2026-10-28 (read-only, `--billing-project` = seed): the constraint is `iam.managed.disableAccessPolicyBinding` (singular; the plural name returns NOT_FOUND), effective `enforce: false` on the runtime project. No change needed; re-check on the run day.
   - Grant the operator `roles/iam.accessPolicyAdmin` on the runtime project (needed to create the policy and binding; not covered by the kept org roles). Record the grant.
   - Wait after the apply: not documented; use 10 minutes (as for deny policies) before T30.
4. If the token-binding change does not remove the 401, T30-T32 are INCONCLUSIVE again; record and stop area B (no further retries that day).
