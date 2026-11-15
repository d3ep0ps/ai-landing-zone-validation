# Run 7 (all tests; second run of v2)

Order: [tests/RUN-ORDER-run7.md](../../tests/RUN-ORDER-run7.md). Start: 2026-10-28 (day 1).

## Inputs recorded before the run

- T04 inputs (same as runs 1, 2, 5, 6): T04_DENIED_MODEL=gemini-4-argon, T04_LOCATION=global.
- T19 (P4, carried over from the run-6 human decision 2026-10-27): the agentDefaultAccess binding already exists in the runtime project (F14); added=0 is accepted and recorded.
- Pre-run checks 2026-10-28 (read-only): KMS version 1 of both keys ENABLED (restored by the human); operator holds roles/iam.accessPolicyAdmin on the runtime project (granted by the human); org-level floorSettingsAdmin and denyAdmin kept; T39b control SA kept (no keys); `iam.managed.disableAccessPolicyBinding` effective enforce false on the runtime project.
- Area B setup differs from run 6 (human decision 2026-10-28): agent G token binding opt-out, pinned agent G packages, IAP policy V2. Expected results unchanged.

## Day 1 (2026-10-28)

- Precheck: active config lz-validation, account and organization match PROGRESS.md; user and ADC tokens valid.

### Stage 1-0a
- Plan `infra/plan-run7-stage1-0a.tfplan`: 2 to import (DC3 key ring and key), 10 to add (DC3 bucket, KMS API, key binding, bucket grants; DC4 sink and 2 grants; Model Armor API and template `lzv-ma-pi`), 1 in-place (imported key labels/rotation), 0 to destroy (SWP leftovers were removed in run 6).
- Applied by human: 2 imported, 10 added, 1 changed, 0 destroyed (DC3 bucket `PROJECT_8-lzv-build-cmek`, DC4 sink `lzv-dc4-admin-activity`, template `lzv-ma-pi`).

### Stage 1-0b (org scope, alone)
- First plan attempt failed on local network errors (`can't assign requested address`, `http2: client connection lost`; no plan file). Retry: plan `infra/plan-run7-stage1-0b.tfplan`: 3 to add: custom constraint `custom.lzvOrgTestBucketLabel`, org policy with `dry_run_spec` only (enforce TRUE), outside-project policy with `dry_run_spec` enforce FALSE (exception). No live `spec`.
- Apply attempt 1 (human): custom constraint create refused with `invalid_grant ... reauth related error (invalid_rapt)` (ADC login expired); nothing created (no t36 resource in state). Re-plan after a fresh ADC login.
- Applied by human (r2 plan, ~15:27:12Z): 3 added (custom constraint, org dry-run policy, outside-project exception). T36 `dryrun` not before 15 min after this.

### Stage 1-2 (plan prepared during 1-1; apply only after T36 `dryrun` finishes)
- Plan `infra/plan-run7-stage1-2.tfplan`: 7 to add: folder policies T05, T06, T07; Model Armor folder floor and runtime-project floor (both `enable_floor_setting_enforcement = true`; `v2_ma_floor_enforce` set back to folder/project true after the run-6 reset); Vertex AI service identity and its `roles/modelarmor.user`.

### Stage 1-1 (15:27Z-15:31Z, base state, T36 dry-run policy present)
- PASS: T01, T02, T03, T17, T04 (denied model gemini-4-argon), T08, T09, T15, T24, T28; stages PASS: T06 `before`, T13 `setup`, T13 `dryrun`. No script faults (the run-6 fixes held).
- T02, T03, T17 "cleanup step failed": the delete/describe of the refused service (never created) returned not found; the created services were deleted. 0 Cloud Run services left in the mcp project (checked).
- T36 `dryrun` (15:42:33Z-15:44:52Z): stage PASS: unlabeled bucket create allowed in the data project; audit entry `dryRunResult=DENIED`, `liveResult=ALLOWED`; test bucket deleted.
- Applied by human (~15:47:33Z): 7 added (floors created after 32 s). Tests not before 15 min after this (2026-10-28T16:03:03Z).

### Stage 1-3a (targeted; plan prepared during the 1-2 wait, apply after the 1-2 tests)
- Plan `infra/plan-run7-stage1-3a.tfplan`: 2 to import (T25 ring and key), 5 to add (2 T25 APIs, signer binding, Container Analysis note, attestor; no Binary Authorization policy), 2 in-place (folder floor enforcement true -> false; imported key labels), 3 to destroy (T05, T06, T07 folder policies). Same as run 6.

### Stage 1-2 tests (16:03Z-16:09Z, 15 min after the apply)
- PASS: T05, T06 (`before` + `after`), T07, T10, T20, T21, T27.
- T29: FAIL, same as run 6 (expected text unchanged): flagged prompt blocked (`MODEL_ARMOR`, HTTP 200), benign control answered, but the message does not start "Blocked by Floor Setting" (F15). Repeated in run 7.
- Applied by human (~16:16Z): 2 imported, 5 added, 2 changed, 3 destroyed. (Output org_policy_ids still lists T05-T07: targeted apply does not refresh outputs; policies destroyed.)

### Stage 1-3b (org scope, alone, targeted at the three T36 resources)
- Plan `infra/plan-run7-stage1-3b.tfplan`: 2 in-place: org policy dry_run_spec -> spec (enforce TRUE); outside-project policy dry_run_spec -> spec (enforce FALSE, exception). Same as run 6.
- Applied by human (~16:17Z): 2 changed. T36 enforced from here until 1-5b.

### Stage 1-3c (org scope, alone, targeted)
- Plan `infra/plan-run7-stage1-3c.tfplan`: 2 to add: Model Armor API in the data project (T38 test project) and the org floor setting (`organizations/<org>/locations/global`, enforcement on). Same as run 6.
- Applied by human (~16:19:15Z): 2 added (org floor created after 32 s). T36 `enforce` and T38 not before 2026-10-28T16:34:45Z.

### Stage 1-4 (plan prepared during the 1-3 wait)
- Plan `infra/plan-run7-stage1-4.tfplan` (targeted `module.t25_binauthz`): 1 to add: Binary Authorization policy in the mcp project (REQUIRE_ATTESTATION, ENFORCED_BLOCK_AND_AUDIT_LOG). Apply after T36 `enforce` and T38. T36 stays enforced through 1-4 (T25 creates no bucket).

### Stage 1-3 tests (16:35Z, 15 min after 1-3c)
- T36: PASS (dryrun stage PASS; enforce: unlabeled create refused in the data project with `customConstraints/custom.lzvOrgTestBucketLabel`, same create in the exception project succeeded; test buckets deleted).
- T38: PASS (template at the org floor created; filter-off and HIGH-only templates refused and not created).
- Applied by human (~18:30Z): 1 added (Binary Authorization policy).
- T25: PASS (unattested digest refused; same digest deployed after attestation). Human cleanup pending: Artifact Registry repository `lzv-t25-run7-ma53k4` (mcp).

### Stage 1-5 (day-1 reset: project scope, then each org-scope change alone)
- 1-5a plan `infra/plan-run7-stage1-5a.tfplan` (full plan; tfvars: DC3, DC4, T25, P2 import off; project floor enforcement off; T36 and org floor unchanged): 1 in-place (project floor enforcement -> false), 18 to destroy (T25 policy, attestor, note, signer binding, 2 APIs; DC3 bucket, grants, KMS API, key binding; DC4 sink and 2 grants; both KMS rings and keys, state only: Terraform schedules version destruction again). Same as run 6.
- 1-5a applied by human (~18:34Z): 1 changed, 18 destroyed.
- mcp Binary Authorization default rule back to `evaluationMode: ALWAYS_ALLOW` (checked).
- 1-5b plan `infra/plan-run7-stage1-5b.tfplan` (org scope, alone, targeted): 3 to destroy: T36 org policy, exception-project policy, custom constraint.
- 1-5b applied by human (~18:35Z): 3 destroyed (T36 constraint and policies gone).
- 1-5c plan `infra/plan-run7-stage1-5c.tfplan` (org scope, alone, targeted): 1 in-place: org floor enforcement true -> false.
- 1-5c applied by human (~18:36Z): 1 changed (org floor enforcement off).
- 1-5d plan `infra/plan-run7-stage1-5d.tfplan` (full, untargeted; tfvars identical to the start of day 1): 8 to destroy (3 floor settings, all non-enforcing; template `lzv-ma-pi`; Vertex service agent grant and identity entry; 2 Model Armor API entries), nothing else. Same as run 6.
- 1-5d applied by human (~18:37Z): 8 destroyed.
- Checks after 1-5d: untargeted plan "No changes" (exit 0); T36 custom constraint gone at the org; 0 Cloud Run services in mcp; KMS version 1 of both keys DESTROY_SCHEDULED (2026-11-27), as expected (a later run needs the restore again). Open: T25 Artifact Registry repository `lzv-t25-run7-ma53k4` awaits the human delete. Floor settings stay in GCP, non-enforcing (F20).

### Day 1 summary (2026-10-28)
- Tests: 21 PASS, 1 FAIL (22 tests with a verdict). PASS: T01-T10, T15, T17, T20, T21, T24, T25, T27, T28, T36, T38; multi-stage parts: T13 `setup`/`dryrun` PASS (finishes on day 2). FAIL: T29 (message prefix; block itself worked), same as run 6.
- Verdicts identical to run-6 day 1. No script faults. Infra/ops faults: one 1-0b plan attempt hit local network errors; one 1-0b apply hit an expired ADC login (`invalid_rapt`), nothing created, re-planned after a fresh login.
- State at the end of day 1: org back to its baseline (T36 gone; floors present, non-enforcing); no paid resources left; KMS rings and keys out of state, versions scheduled for destruction.

## Day 2 (2026-10-29)

- 2-0 precheck: active config lz-validation, account matches; tokens valid. Perimeter lzv_ai: dry-run spec 3 projects (runtime included), status 0, no ingress/egress rules. 0 reasoning engines in the runtime project. T25 Artifact Registry repository deleted by the human (0 left).
- 2-0 applied by human (gcloud; verified 04:30:36Z): runtime project removed from the dry-run spec (spec 2 projects; runtime in neither spec nor status; no ingress). Wait 15 until ~04:45:36Z.
- T19 `before` (run-7): stage PASS (IAM snapshot, during the 2-0 wait).
- 2-1 plan: infra/agents plan-run7-stage2-1.tfplan, 1 add (agent A reasoning engine). Apply after the 2-0 wait (04:45:36Z).
- 2-2 plan (prepared during the 2-0 wait): infra plan-run7-stage2-2.tfplan (full, untargeted; tooling_quota_project = data project): 1 in-place change, only the runtime project added back to the lzv_ai dry-run spec; output tooling_quota_project. Apply after the 2-1 tests.
- 2-1 applied by human: agent A creation complete 04:35:38Z after 2m35s (started ~04:33Z). **Deviation (same as run 6):** started ~12 min before the 2-0 wait ended (04:45:36Z), although RUN-ORDER-run7 says "after". Same assessment as run 6: the 2-0 change only removed the runtime project from the dry-run spec, which blocks nothing; the possible effect is dry-run violation entries for the deploy calls; T19, T14 `a`, T23 `pre` do not depend on dry-run logging. Not redeployed (cost, pacing rule).
- Stage 2-1 tests (04:36Z-04:37Z): T11 PASS; T12 FAIL (same as run 6: platform grant roles/aiplatform.agentDefaultAccess on the runtime agent principalSet; analyzer finds the path, 1; control query 19); T19 `after` PASS (added=0, extra none, removed none; P4 decision); T14 `a` PASS; T14R `pre` PASS; T23 `pre` PASS.
- 2-2 applied by human (~04:37:55Z): spec back to 3 projects, status 0. T22 `dryrun` not before 2026-10-29T04:53:15Z.
- 2-3 plan (prepared during the 2-2 wait): infra plan-run7-stage2-3.tfplan, -target=module.vpc_sc: 1 in-place change, status added (3 projects; storage, aiplatform), no ingress rules. Apply after T22 `dryrun`.
- Rule files for 2-4a/2-4b in scratch/run7-day2/ (copied from run 6; 2-4b agent A identity = run-7 engine ...831488; egress target = seed project number, checked).
- T22 `dryrun` (run-7, 04:53Z-04:56Z): stage PASS (dry-run violations last 30 min: old quota project 4, tooling quota project 0).
- 2-3 applied by human (~04:58:25Z): status 3 projects (storage, aiplatform), no ingress. T13 `outside-read` not before 2026-10-29T05:13:45Z.
- T13 `outside-read` (run-7, 05:13Z-05:15Z): stage PASS.
- 2-4a applied by human (gcloud; verified 05:17:07Z): status and spec = 3 projects, ingress [operator: operator user + T39b control SA], egress [storage buckets.list + serviceAccounts.getOrCreate to the seed]. Wait 15 from 05:17Z (apply time not seen) until 2026-10-29T05:32:37Z.
- tfvars updated to match 2-4a (operator ingress on, T39b control SA as extra identity, pipeline egress = storage 2 methods to the seed).
- T14R `post` (run-7, 05:32Z): INCONCLUSIVE (as run-3 and run-6): no function response; agent A's own API call refused by VPC-SC without the agent ingress rule. Pre-registered as INCONCLUSIVE for this case.
- 2-4b applied by human (gcloud; verified 05:37:54Z): status and spec ingress [operator (2 identities), agents (A)], egress 1. Wait 15 until ~05:53Z; during it T13 `copy`, T22 `enforced`, T39, T39b.
- 2-5 plan: infra/agents plan-run7-stage2-5.tfplan, 1 add (agent B); agent A "has changed" is a refresh note only. Apply after the 2-4b wait (~05:53Z); A deployed 04:35Z, so the 30-min spacing holds.
- T13 `copy` (run-7): stage PASS; T13 result PASS (violationReason RESOURCES_NOT_IN_SAME_SERVICE_PERIMETER).
- T22 `enforced` (run-7): FAIL, same as run-5-r2 and run 6: one plan error, the GCS service-account lookup refused with 403 (VPC-SC); read exit 0; violations naming the tooling quota project 0.
- T39 `split` (run-7): stage PASS (inside plan exit 2, outside plan exit 2; enforced violations naming either quota project 0). T39b `egress`: stage PASS (single-stack full plan with the seed quota project exit 2; violations naming the seed 0; control identity refused). T39 result PASS.
- 2-4b drift check (untargeted plan, seed quota project, -lock=false; scratch/run7-day2/plan-2-4b-drift.txt): only diff = order of the two operations in the operator ingress rule (storage/aiplatform swapped), status and spec; no additions or removals. Same as run 6; not applied. (A first attempt with the data quota project hit the T22 outside-project lookup error, as expected.)
- 2-5 applied by human: agent B creation complete 07:34:21Z (2m26s), engine ...828736. (Started ~07:32Z, ~1h40 after the 2-4b wait ended; the perimeter state was unchanged in between.)
- T14 `b` (run-7): PASS (T14 result PASS). T18 `pre` (run-7): stage PASS (agent B calls work without its own ingress rule, as in v1 and run 6).
- 2-5b applied by human (gcloud; verified 07:37:22Z): agents ingress 2 identities (A, B) on status and spec. T23 `post` not before 2026-10-29T07:52:42Z (before 2-6: the deny policy affects B).
- tfvars agent ingress = [A, B] (mirrors 2-5b). 2-6 plan (during the T23 wait): infra plan-run7-stage2-6.tfplan, -target=google_iam_deny_policy.dc1_agents_predict: 1 add (project deny on the runtime agent principalSet, exception = run-7 agent A). Apply after T23 `post`. Wait 10 after apply.
- T23 `post` (run-7, 07:52Z): PASS (pre: A tool 200; post: A tool 200; B tool URLError Network is unreachable).
- 2-6 applied by human (~07:56:41Z): deny policy lzv-dc1-deny-agent-predict on the runtime project, exception [A]. T18 `post` not before 2026-10-29T08:07:01Z.
- 2-6b plan (during the 2-6 wait; -var enable_dc1_deny=false -var enable_v2_folder_deny=true, tfvars unchanged until T18 post): infra plan-run7-stage2-6b.tfplan, targeted at both deny policies: 1 destroy (project deny), 1 add (folder deny "T37: deny endpoints.predict to org agents except approved", principalSet .../*, exception [A]).
- Agent C source rebuilt locally (tests/fixtures/agent_c/build.sh -> infra/agents/build/source-c.tar.gz).
- T18 `post` (run-7, 08:07Z): PASS (B refused PERMISSION_DENIED; A answered; policy age 639s). tfvars set to the 2-6b values (enable_dc1_deny=false, enable_v2_folder_deny=true).
- 2-6b applied by human (~08:07:56Z): project deny destroyed, folder deny lzv-v2-deny-agent-predict on fldr-lz-validation, exception [A] (first attempt; the run-6 display-name fix held). T37 not before 2026-10-29T08:18:16Z.
- 2-7 plan (during the T37 wait; -var enable_v2_folder_deny=false swp_enabled=true enable_v2_psci=true): infra plan-run7-stage2-7.tfplan, targeted at the folder deny, SWP (API, VPC, subnets, route, firewall, gateway, policy, rule) and PSC-I (network attachment, aiplatform service identity, networkAdmin grant): 20 add, 1 destroy (folder deny). Perimeter excluded: the full probe plan shows only the operations-order diff (4 swapped service_name lines). Same as run 6. After the apply: saved refresh-only plan for the outputs.
- T37 (run-7, 08:18Z): PASS (Enforced): agent B refused PERMISSION_DENIED (deny wording present), agent A answered, folder policy age 639s, project policy absent. Second run of T37 (C25 repeated). tfvars set to the 2-7 values.
- 2-7 applied by human (~11:52Z): 20 added (SWP gateway lzv-swp, proxy http://10.77.0.10:443, PSC-I attachment lzv-psci), folder deny destroyed. Agent C queries not before 10 min after this. Output v2_psci_attachment_name missing (targeted apply), as in run 6.
- Refresh-only plan plan-run7-refresh-only.tfplan: 34 state syncs (IAM etags, computed fields of new SWP/VPC resources, perimeter refreshed from the gcloud changes), no resource changes, output v2_psci_attachment_name added. Same as run 6.
- Refresh-only applied by human (~11:57Z): 0/0/0, output v2_psci_attachment_name written.
- T16 (run-7): PASS (allowed host via proxy 200; non-allowed host 403 on CONNECT; gateway_requests DENIED entry present; bypass timed out, not DNS). 3 Cloud Run jobs left for the human to delete (lzv-t16a/b/c-run7-*).
- 2-7c plan: infra/agents plan-run7-stage2-7c.tfplan: 2 add (agent C with network_attachment lzv-psci and PROXY_SERVER_URL; terraform_data inputs). Agent B "has changed" = refresh note. B deployed ~07:32Z, folder deny removed with the 2-7 apply: spacing and the 10-min wait hold.
- 2-7c applied by human: agent C creation complete ~12:02Z (2m55s), engine ...146368.
- 2-8a plan (during T33/T34): infra/agents plan-run7-stage2-8a.tfplan: 4 destroy (agents A, B, C, agent C inputs).
- 2-8b plan: infra plan-run7-stage2-8b.tfplan (untargeted; tfvars restored to the start-of-day file: enforcement off, no ingress/egress, tooling_quota_project null, SWP, PSC-I and deny toggles off): 20 destroy (SWP, VPC, PSC-I attachment, firewall, APIs, networkAdmin grant), 1 change (perimeter: status removed; ingress and egress removed from spec). Same as run 6. Apply after T33/T34 and 2-8a.
- T33 (run-7): PASS (Enforced): agent C (PSC-I) via the SWP: allowed host 200; www.wikipedia.org refused on CONNECT (403); gateway_requests DENIED entry names wikipedia. Second run of T33 (C23 repeated).
- T34 (run-7): INCONCLUSIVE, same as run 6: control via proxy 200; direct connection to example.com failed (NewConnectionError, not DNS), but no firewall log DENIED entry for lzv-swp-deny-egress-all from 10.77.4.0/28 in ~10 min. Follow-up read: the runtime project has 0 firewall log entries since 11:15Z (F18 repeated).
- 2-8a applied by human: agents A, B, C destroyed (0 reasoning engines in state). T16 jobs deleted by the human (0 jobs).
- 2-8b applied by human: partly. Error 400 on subnet `lzv-swp-job`: in use by `serverless-ipv4-cloudrun-…` (RESERVED, SERVERLESS), the Cloud Run serverless address that run 5 also saw (run 6 did not). Left in state: subnet lzv-swp-job, VPC lzv-swp-vpc, 4 SWP API entries (no cost). Destroyed: SWP gateway, policy, rule, firewall rules, routes, proxy-only and PSC-I subnets, network attachment, networkAdmin grant, aiplatform identity. Perimeter reset applied: status empty (not enforced), dry-run spec 3 projects, no ingress/egress.
- Plan: re-plan and apply 2-8b once the serverless address is released (it is Google-managed; it went away by itself after run 5).
- Check 2026-10-29 (after 2-8b): serverless address still RESERVED (created 11:54Z by the T16 jobs). Same as run 5, where it stayed past the end of the day. Not deleted by hand (Google-managed).

### Day 2 summary (2026-10-29)

- PASS: T19, T11, T14 (a, b), T23, T13 (outside-read, copy), T39, T39b, T18, T37, T16, T33; T22 dryrun stage PASS.
- FAIL (same as run 6): T12 (platform grants agentDefaultAccess to the agent principalSet), T22 enforced (outside-project GCS service-account lookup refused by VPC-SC).
- INCONCLUSIVE (same as run 6 / earlier runs): T14R (agent's own API call refused without the agent ingress rule), T34 (no firewall log entries; F18 repeated).
- Deviation: agent A deploy started ~12 min before the 2-0 wait ended (same as run 6).
- Reset: agents 0, jobs 0, deny policies 0, perimeter dry-run spec 3 projects, no ingress/egress, status empty. Open: SWP job subnet, VPC and 4 API state entries (free), held by the serverless address. Next: re-plan 2-8b (`plan-run7-stage2-8b-r2.tfplan`) once the address is gone; the day-3 precheck must check this first.
- 2026-10-29 ~19:15Z: serverless address gone (0 SERVERLESS addresses; subnet lzv-swp-job left). 2-8b-r2 plan: infra plan-run7-stage2-8b-r2.tfplan (untargeted): 0 add, 0 change, 6 destroy (job subnet, VPC, 4 SWP API state entries). Only the SWP leftovers; no other drift.
- 2-8b-r2 applied by human (~19:20Z): 6 destroyed. Reset verified: infra and infra/agents plans "No changes"; runtime project has no VPC networks; perimeter status empty, dry-run spec 3 projects, no ingress/egress; no deny policies on the runtime project or the test folder. Day 2 closed; environment at base for day 3.

## Day 3 (2026-10-29, evening)

- Human decision 19:22Z (21:22 local): start day 3 now. Teardown is expected around or after local midnight, so the paid resources may cross into 2026-10-30 (deviation from "destroyed the same day", recorded).
- 3-0 precheck (read-only, 19:19Z-19:21Z): active config lz-validation, account matches; seed and runtime have networkservices, networksecurity, agentregistry, iap, modelarmor, iam enabled; P8: iam.managed.disableAccessPolicyBinding effective on the runtime project = enforce false; 0 reasoning engines, 0 Cloud Run services. Gateway region preflight skipped (run 6: create accepted in europe-west1).
- 3-0a plan (19:25Z): infra plan-run7-stage3-0a.tfplan (untargeted; tfvars enable_v2_gateway=true, enable_v2_model_armor=true): 44 add, 0 change, 0 destroy. IAP V2: access policy lzv-gw-egress + project binding (ACCESS); no V1 egressor grant; extension iapPolicyVersion V2.
- 3-0a applied by human (verified 19:42Z): all 44 planned resources in state; gateway lzv-gw; access policy lzv-gw-egress and policy binding lzv-gw-egress (ACCESS) present at global. Registry entries created ~19:40Z; agent G deploy not before ~19:45Z.
- 3-0b (Opus, 19:42Z-19:47Z): setup.sh build (Cloud Build in europe-west1, regional staging bucket) SUCCESS; setup.sh deploy: lzv-mcp-reg, lzv-mcp-unreg deployed, run.invoker for the runtime agent principalSet rc=0.
- Agent G source built (agent_g/build.sh; requirements pinned google-cloud-aiplatform[agent_engines,adk]==2.6.0, google-adk==2.13.0). 3-0c plan: infra/agents plan-run7-stage3-0c.tfplan: 2 add (agent G with agent_gateway_config -> lzv-gw, env GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=False; inputs).
- 3-0c applied by human: agent G engine AGENT_ID_19 (updateTime 19:48:44Z). Read-only check: env GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=False present; agentGatewayConfig agentToAnywhereConfig -> lzv-gw.
- 3-0d plan: infra plan-run7-stage3-0d.tfplan, -target=google_iam_deny_policy.dc1_agents_predict: 1 add (project deny, T18 form, exception [G ...242176]). tfvars enable_dc1_deny=true, exception = G.
- 3-0d applied by human: deny policy lzv-dc1-deny-agent-predict created 19:50:28Z (exception G). Wait 10 (also IAP V2 policy) until 20:00:28Z; T30, T32, T31 part 1 after that.
- 20:00Z-20:03Z T30, T32, T31 (run-7): all INCONCLUSIVE. Control registered_echo answered **404** (status 404, auth id_token). The run-6 401 is gone: every agent platform call through the gateway answered 200 (sessions, telemetry; IAP V2 policy ALLOWED, Model Armor policy ALLOWED). Gateway log for the registered call: lzv-gw-iap-policy=ALLOWED, lzv-gw-ma-policy=ALLOWED, upstream status 404 (Google front-end page "/mcp was not found"), 0 request-log entries on lzv-mcp-reg. Unregistered call: 403, lzv-gw-iap-policy=DENIED, 0 origin entries. Cause (fixture): lzv-mcp-reg has ingress "internal"; the gateway has no VPC egress (v2_gateway_network_attachment = null), so Cloud Run refuses it before the container. Docs do not state the status for ingress-blocked requests (docs.cloud.google.com/run/docs/securing/ingress, fetched 2026-10-29); attribution from the log.
- Human decision 20:1xZ (AskUserQuestion): one fixture fix allowed (stop-rule exception): ingress all on lzv-mcp-reg and lzv-mcp-unreg (IAM invoker auth unchanged), then re-run T30/T32/T31 as run-7-r2; same stop rule after that. Expected results unchanged.
- Fixture fix attempted by human (gcloud run services update lzv-mcp-reg --ingress=all): refused, FAILED_PRECONDITION "Constraint constraints/run.allowedIngress violated" (folder policy, allowedValues [internal]; the T02 control). Nothing changed. The fix would need the landing-zone control weakened (not done) or VPC egress for the gateway (network attachment; unverified, needs the VPC rebuilt). Stop rule applied: T30, T31, T32 run-7 INCONCLUSIVE; 3-1b (agent B) skipped; go to 3-2.
- **Finding (area B, run-7):** with the token-binding opt-out and IAP policy V2, agent G's calls through the gateway work (no 401; IAP V2 ALLOWED registered destinations and DENIED the unregistered MCP tool with 403 at the gateway, no origin request). The registered MCP fixture is unreachable from the gateway: Cloud Run ingress "internal" (required by the folder policy run.allowedIngress) refuses it with 404 before the container. Test-design gap: an Agent Gateway without network_config egress cannot reach internal-only Cloud Run in a landing zone that enforces run.allowedIngress=internal. Next run: gateway egress through a network attachment (v2_gateway_network_attachment), to be doc-checked first.
- 3-2 (reset) started ~20:15Z. teardown.sh run: lzv-mcp-reg and lzv-mcp-unreg delete HTTP 200. Plans: infra/agents plan-run7-stage3-2a.tfplan (2 destroy: agent G + inputs); infra plan-run7-stage3-2b.tfplan (untargeted, tfvars restored to the pre-3-0a file: 45 destroy = the 44 gateway/Model Armor/IAP V2 resources + the project deny policy).
- 3-2a and 3-2b applied by human (3-2b with -parallelism=1); human deleted gs://<runtime>_europe-west1_cloudbuild. Reset verified 21:35Z: infra and infra/agents plans "No changes"; 0 agent gateways, 0 reasoning engines, 0 Cloud Run services, 0 Artifact Registry repos; no access policy or policy binding lzv-gw-egress; 0 deny policies on the runtime project. Gateway lived ~19:40Z-~21:30Z (inside 2026-10-29 UTC and local). Leftover not from today: gs://<runtime number>-europe-west1-cloudbuild-logs (Cloud Build regional log bucket, created 2026-10-28 09:41Z in run 6; build logs only); listed for the after-run cleanup (human).

### Day 3 summary (2026-10-29)

- T30, T31, T32: INCONCLUSIVE (stop rule after one refused fixture fix). Agent B (3-1b) not deployed.
- Change from run 6: the 401 is gone with the token-binding opt-out (pinned packages, IAP V2). Gateway evidence: IAP V2 ALLOWED registered destinations and DENIED the unregistered MCP tool (403 at the gateway, no origin request); Model Armor policy ALLOWED clean traffic.
- Blocker: internal-only Cloud Run fixture (required by run.allowedIngress) is unreachable from a gateway without VPC egress (404 before the container). Next run: doc-check gateway network_config egress via a network attachment.
- Deviations: one stop-rule exception (ingress fix, refused by the folder policy, nothing changed).

## Redaction (2026-10-29)

- tools/redact.py run in place on the run-7 evidence and this log (178 files, 142 changed); `--check` 0 findings.
- redaction-checker (independent scan, run-7 scope, 179 files): 0 hits for org ID, domain, project numbers/IDs, principal URIs, run.app numeric hosts, tokens, keys, billing IDs; emails only placeholder service agents; `eyJ` hit is Model Armor byteData, not a JWT. Its FAIL concerned infra/ state and tfvars files (git-ignored, out of scope). Review items resolved by Opus: random test bucket names (lzv-tNN-run7-xxxxxx) kept, as in committed runs 1-6 (deleted resources, no identifier); infra/v11-swp.tf comment CIDR is Google's documented restricted.googleapis.com range.

## Report review (2026-10-29)

- evidence-reviewer (fresh context) on the run-7 report diff: verdicts and counts correct; T30-T32 wording overclaimed. Fixed in the reports: (1) T32 "Model Armor finding logged" is a matcher fault (`MATCH_FOUND` matches `NO_MATCH_FOUND`; all entries NO_MATCH_FOUND; the injected response never passed the gateway); (2) the T30/T31 scripts' log checks did not isolate a gateway DENIED entry (counts included the query's own audit entry and ALLOWED entries matched on rule name `default_denied`); (3) not every forwarded call answered 200 (two telemetry traces 403, one iamcredentials 404, policies ALLOWED); (4) Finding 25 sources named (run log; raw request-log check not stored); F9 evidence list completed.
- Post-run lookup (read-only, Opus, after the review): gateway_requests log for 20:00:30Z-20:03:30Z saved per test window as evidence/T30|T31|T32/run-7/post-gateway-log-lookup.txt (labelled post-run, redacted). It shows lzv-gw-iap-policy=DENIED + 403 for T30's unregistered MCP call (20:00:51Z) and T31's blocked endpoint (20:02:37Z); no entry for T32's two tool calls. Verdicts unchanged.
- Correction (2026-10-30, doc check notes/doc-verification-v2-B-netattach.md): the Day-3 entry says the docs do not state the status for ingress-blocked requests. They do: the Cloud Run troubleshooting page lists HTTP 404 for "A request doesn't satisfy the specified network restriction" (ingress Internal) and says these 404s are not in Cloud Logging. The earlier entry is left as written.
