# Run 6 (all tests: v1, v1.1, v2)

Order: [tests/RUN-ORDER-run6.md](../../tests/RUN-ORDER-run6.md). Start date: not set yet (human).

## Inputs recorded before the run

- T04 inputs (same as runs 1, 2 and 5): T04_DENIED_MODEL=gemini-4-argon, T04_LOCATION=global.
- T19 (P3, human decision 2026-10-27): the agentDefaultAccess binding already exists in the runtime project (F14); added=0 is accepted and recorded, not a new result.

## Pre-run fixture work (2026-10-27)

- Day-3 APIs enabled on the seed (quota) project: networkservices, networksecurity, agentregistry, iap (modelarmor already on).
- T39b control identity: `T39B_OTHER_SA=SA_11@PROJECT.iam.gserviceaccount.com` (no keys). Before the run, the control was made stricter: the identity is added to the operator ingress rule (`vpc_sc_operator_ingress_extra_identities`, stage 2-4) and the control passes only on an enforced egress violation for that identity naming the seed project. As first written, the identity had no ingress rule, so an ingress refusal would have counted as the control. The expected-result texts did not change.

- P2 path A: version 1 of `lzv-build-key` (runtime) and `lzv-attestor-key` (mcp) restored (DISABLED) and then enabled (ENABLED); all commands exit 0. Rings and keys are still outside Terraform state until the `p2_import_existing_kms=true` apply at stage 1-0.
- `modelarmor.googleapis.com` enabled on the seed (quota) project.
- Model Armor operator roles (floorSettingsAdmin on the org, test folder and runtime project; modelarmor.admin on the runtime and data projects): granted by the human 2026-10-27, all five checked with get-iam-policy. The org-level grant is removed at teardown.
- Agent Gateway region check (documentation, 2026-10-27): europe-west1 is a supported Agent Gateway location (the † exclusions cover asia-east2, asia-northeast3 and asia-southeast2 only); Agent Registry also lists europe-west1. A REST list call is not conclusive (any valid region returns 200). The real check is the gateway create in day-3 preflight 3-0.
  - https://docs.cloud.google.com/gemini-enterprise-agent-platform/resources/agent-locations
  - https://docs.cloud.google.com/agent-registry/locations
  - https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/gateways/agent-gateway-ge-deploy

## Day 1 (2026-10-27)

Changes to the order before any test ran: stage 1-0 split into 1-0a (project scope) and 1-0b (`t36_mode="dryrun"` alone, as the README requires for org-scope toggles); T25 removed from 1-0 (its one toggle also turns on the Binary Authorization policy, which would refuse T17's positive control in 1-1) and its first, targeted apply moved to the start of 1-3.

### Stage 1-0a
- Plan `infra/plan-run6-stage1-0a.tfplan`: 2 to import (DC3 key ring and key), 10 to add (DC3 bucket, KMS API, key binding, bucket grants; DC4 sink and grants; Model Armor API and template `lzv-ma-pi`), 1 in-place change (imported key gains rotation period and labels), 6 to destroy (SWP leftovers, P1).
- Apply attempt 1 (human): the two imports completed (state only); every create/destroy refused with `invalid_grant ... reauth related error (invalid_rapt)` on the ADC login, so nothing changed in GCP (state checked). The saved plan is stale after the imports; re-plan after a fresh ADC login.
- Apply attempt 2 (plan `plan-run6-stage1-0a-r2.tfplan`, human): 10 added, 1 changed, 6 destroyed. DC3 bucket `PROJECT_8-lzv-build-cmek`, DC4 sink `lzv-dc4-admin-activity`, Model Armor template `lzv-ma-pi`; SWP leftovers gone (P1 closed; the 4 APIs stay enabled).

### Stage 1-0b (org scope, alone)
- Plan `infra/plan-run6-stage1-0b.tfplan`: 3 to add: custom constraint `custom.lzvOrgTestBucketLabel` (org), org policy with `dry_run_spec` only (enforce TRUE), outside-project policy with `dry_run_spec` enforce FALSE (exception). No live `spec`.
- Rollback: `gcloud org-policies delete custom.lzvOrgTestBucketLabel --project=<outside>` and `--organization=<org>` (infra/README.md "v2 T36"), or `t36_mode="off"`.
- Applied by human ~12:57Z (3 added). T36 `dryrun` not before 15 min after this.

### Stage 1-1 (12:58Z-13:05Z, base state, T36 dry-run policy present)
- PASS: T01, T02, T03, T17, T04 (denied model gemini-4-argon), T08, T09, T15, T24; stages PASS: T06 `before`, T13 `setup`, T13 `dryrun`.
- T28: first attempt aborted in its precheck (`aborted-20261027T130318Z`, no verdict): `gcloud model-armor` sent the call to `modelarmor.us-central1.rep.googleapis.com` although `--location=europe-west1`, and was refused with PERMISSION_DENIED (REST to the europe-west1 endpoint returned 200 for the same template). Script fix 6c0b8af (endpoint overrides in T27, T28, T29, T38: templates regional, floor settings global); expected texts unchanged. Re-run as `run-6`: PASS (sample MATCH_FOUND with pi_and_jailbreak matched; benign controls NO_MATCH_FOUND).

### Stage 1-1, last test: T36 `dryrun`
- Attempt 1 (13:12Z) aborted in its precheck, no verdict: the exception-policy guard used jq `.enforce // true`, which turns `false` into `true`; the policy itself had `dryRunSpec.rules[0].enforce=false`. Script fix dcbf74f (guard only; expected texts unchanged). Attempt 2 started after the fix under the same RUN_ID (multi-stage test: the abort stays in output.txt).

### Stage 1-2 (plan prepared during T36; apply only after T36 finishes)
- Plan `infra/plan-run6-stage1-2.tfplan`: 7 to add, 0 change, 0 destroy: folder policies for T05, T06, T07 (fldr-lz-validation); Model Armor folder floor (folder, pi_and_jailbreak MEDIUM_AND_ABOVE, enforcement on); project floor in the runtime project with AI_PLATFORM integration, inspect_and_block; Vertex AI service agent identity and `roles/modelarmor.user` for it.
- Attempt 2 (13:13Z-13:16Z): stage PASS: unlabeled bucket create allowed in the data project; audit entry `dryRunResult=DENIED`, `liveResult=ALLOWED`.
- Stage 1-2 applied by human ~13:22:15Z (7 added; floors created after 33 s).

### Stage 1-2 tests (13:37Z-13:43Z, 15 min after the apply)
- PASS: T05, T06 (`before` + `after`), T07, T10, T20, T21, T27.
- T29: FAIL (recorded, expected text unchanged). The flagged prompt was blocked (`blockReason: "MODEL_ARMOR"`, HTTP 200) and the benign control was answered, but the message is "Blocked by Model Armor Floor Setting: The prompt violated Prompt Injection and Jailbreak filters." and the pre-registered expectation was that it starts "Blocked by Floor Setting" (documentation wording). Finding: the block works; the documented message prefix differs from the observed one.

### Stage 1-3a (targeted)
- Plan `infra/plan-run6-stage1-3a.tfplan`: 2 to import (T25 ring and key), 5 to add (2 T25 APIs, signer binding, Container Analysis note, attestor; no Binary Authorization policy), 2 in-place (folder floor enforcement true -> false; imported key labels), 3 to destroy (T05, T06, T07 folder policies).
- Stage 1-3a applied by human ~14:01Z (2 imported, 5 added, 2 changed, 3 destroyed).

### Stage 1-3b (org scope, alone, targeted at the three T36 resources)
- Plan `infra/plan-run6-stage1-3b.tfplan`: 2 in-place: org policy dry_run_spec -> spec (enforce TRUE); outside-project policy dry_run_spec -> spec (enforce FALSE, exception). Rollback: `t36_mode="off"` (targeted) or the gcloud deletes in infra/README.md "v2 T36".
- Stage 1-3b applied by human ~14:02Z (2 changed). T36 enforced from here until rollback.

### Stage 1-3c (org scope, alone, targeted)
- Plan `infra/plan-run6-stage1-3c.tfplan`: 2 to add: Model Armor API in the data project (T38 test project) and the org floor setting (`organizations/<org>/locations/global`, pi_and_jailbreak MEDIUM_AND_ABOVE, enforcement on, no integrated services). Rollback: `v2_ma_floor_enforce.org=false` + apply, then `enable_v2_ma_org_floor=false` (no delete call), or `gcloud model-armor floorsettings update --full-uri=organizations/<org>/locations/global/floorSetting --enable-floor-setting-enforcement=false`.
- Stage 1-3c applied by human ~14:04:Z (2 added). T36 enforce and T38 not before 15 min after this.

### Stage 1-3 tests (14:19Z-14:20Z, 15 min after 1-3c)
- T36: PASS (dryrun stage PASS; enforce: unlabeled create refused in the data project with `customConstraints/custom.lzvOrgTestBucketLabel`, same create in the exception project succeeded; test buckets deleted).
- T38: PASS (template at the org floor created; filter-off and HIGH-only templates refused and not created).

### Stage 1-4
- T36 stays enforced through 1-4: T25 creates no bucket (staging and logs go to the existing DC3 bucket). Rollback in 1-5.
- Plan `infra/plan-run6-stage1-4.tfplan` (targeted `module.t25_binauthz`): 1 to add: Binary Authorization policy in the mcp project (REQUIRE_ATTESTATION, ENFORCED_BLOCK_AND_AUDIT_LOG, attestor lzv-attestor). No 15-minute wait (not an org policy).
- Stage 1-4 applied by human ~14:27Z (1 added: Binary Authorization policy).
- T25: PASS (unattested digest refused "is not authorized by policy"; same digest deployed after attestation; Cloud Run service deleted by the script). Human cleanup pending: Artifact Registry repository `lzv-t25-run6-kb775c` (mcp).

### Stage 1-5 (day-1 reset, four applies: project scope, then each org-scope change alone)
- 1-5a plan `infra/plan-run6-stage1-5a.tfplan` (full plan): 1 in-place (project floor enforcement -> false), 18 to destroy: T25 policy, attestor, note, signer binding, 2 API entries; DC3 bucket, bucket grants, KMS API entry, key binding; DC4 sink and 2 grants; both KMS rings and keys (state only: rings and keys cannot be deleted, Terraform schedules version destruction again, so run-7 needs the P2 restore again).
- 1-5a applied by human (1 changed, 18 destroyed). mcp Binary Authorization default rule back to ALWAYS_ALLOW (checked).
- 1-5b plan `infra/plan-run6-stage1-5b.tfplan` (org scope, alone, targeted): 3 to destroy: T36 org policy, exception-project policy, custom constraint.
- 1-5b applied by human (3 destroyed): T36 constraint and policies gone.
- 1-5c plan `infra/plan-run6-stage1-5c.tfplan` (org scope, alone, targeted): 1 in-place: org floor enforcement true -> false.
- 1-5c applied by human (1 changed): org floor enforcement off.
- 1-5d plan `infra/plan-run6-stage1-5d.tfplan` (full, untargeted): 8 to destroy, nothing else (no other drift): 3 floor settings (folder, project, org; all non-enforcing), template `lzv-ma-pi`, Vertex service agent grant and identity entry, 2 Model Armor API entries. Whether a floor-setting destroy removes the floor in GCP is unverified; checked after the apply.
- 1-5d applied by human (8 destroyed). Untargeted plan afterwards: "No changes" (exit 0). T25 Artifact Registry repository deleted by the human.
- Observation (answers the "unverified" note in infra/README.md "v2 A"): after the Terraform destroy, all three floor settings (org, folder, runtime project) still exist in GCP with `enableFloorSettingEnforcement` false and their filter config unchanged. With provider 8.8.0 a `google_model_armor_floorsetting` destroy removes the floor from state only; the floor stays, non-enforcing. A later create (run-7) updates the existing floor.

### Day 1 summary
- Tests: 20 PASS, 1 FAIL (21 tests with a verdict). PASS: T01, T02, T03, T04, T05, T06, T07, T08, T09, T10, T15, T17, T20, T21, T24, T25, T27, T28, T36, T38; multi-stage parts passed: T13 `setup`/`dryrun` (T13 finishes on day 2). FAIL: T29 (message prefix; block itself worked).
- Script faults found and fixed before a verdict (aborted prechecks, no verdict lost): gcloud model-armor endpoint (6c0b8af), T36 jq false check (dcbf74f).
- Order changes before the stages ran: 1-0 split (1-0a/1-0b), 1-3 split (1-3a/b/c), T25 first apply moved to 1-3a; 1-5 as four applies (org-scope changes alone).
- State at the end of day 1: org back to its baseline (T36 gone; org floor present but non-enforcing); no paid resources left from day 1; KMS rings and keys out of state, versions scheduled for destruction again.

## Day 2 (2026-10-28)

- 2-0 precheck: perimeter lzv_ai dry-run spec 3 projects (runtime included), status 0, no ingress rules; no reasoning engines in the runtime project. Active config lz-validation, account matches PROGRESS.md.
- 2-0 applied by human (~04:21Z): `gcloud access-context-manager perimeters dry-run update --remove-resources` runtime project. After: spec 2 projects, runtime in neither spec nor status, no ingress. Wait 15 until ~04:37Z.
- T19 `before` (run-6): stage PASS, snapshot evidence/T19/run-6/iam-before.
- 2-1 plan: infra/agents plan-run6-stage2-1.tfplan, 1 add (agent A reasoning engine). Apply after the 2-0 wait (~04:37Z).
- 2-1 applied by human; agent A creation complete 04:28:54Z after 2m36s (started ~04:26Z). **Deviation:** started ~11 min before the 2-0 wait ended (~04:37Z). The 2-0 change only removed the runtime project from the dry-run spec, which blocks nothing; the possible effect is dry-run violation log entries for the deploy calls. T19 (IAM bindings), T14 `a` and T23 `pre` (deploy before enforcement) do not depend on dry-run logging. Not redeployed (cost, pacing rule).
- Stage 2-1 tests (run-6): T11 PASS; T12 FAIL (same finding as run-1/run-2: platform grant roles/aiplatform.agentDefaultAccess on the runtime agent principalSet, which includes predict; **new:** the analyzer now finds the path (1 result) and the control query returns 19 results, both were 0 in run-1/run-2); T19 `after` PASS (added=0, extra none, removed none; decision recorded before the run); T14 `a` PASS; T14R `pre` PASS; T23 `pre` PASS.
- 2-2 plan: infra plan-run6-stage2-2.tfplan (full, untargeted): 1 in-place change, only the runtime project added back to the lzv_ai dry-run spec; output tooling_quota_project = data project. Wait 15 after apply.
- 2-2 applied by human (~04:32:53Z): spec back to 3 projects, status 0. Wait 15 until 04:47:55Z.
- 2-3 plan: infra plan-run6-stage2-3.tfplan, -target=module.vpc_sc: 1 in-place change, status added (3 projects; storage, aiplatform), no ingress rules.
- 04:48Z wait over. T22 `dryrun` (run-6): stage PASS (dry-run violations last 30 min: old quota project 4, tooling quota project 0).
- 2-3 applied by human (~05:09:41Z): status 3 projects (storage, aiplatform), no ingress. Wait 15 until 05:24:41Z.
- 2-4 prep. T39b egress rule built from the dry-run violations naming the seed (vpcsc logs 03:00Z–04:50Z, data/runtime/mcp): only storage.googleapis.com, operator identity, methods `google.storage.projects.serviceAccounts.getOrCreate` (4, from the 2-2 full plan) and `google.storage.buckets.list` (2, T22 control read). Both are listed method selectors (docs.cloud.google.com/vpc-service-controls/docs/supported-method-restrictions, fetched 2026-10-28; storage has no permission selectors). The variable default `serviceusage.googleapis.com` did not match the observed violations. **Note for E2.10:** the quota-project violation for Terraform is a storage call, not serviceusage.
- 2-4 Terraform plan (-target=module.vpc_sc, -var quota_project=data) FAILED: refresh of the projects' GCS service accounts (getOrCreate) refused by VPC-SC, because the operator has no ingress yet (the same reason runs 1–3 added ingress with gcloud). **Run-order change:** 2-4 is applied with gcloud (human): ingress (operator + T39b control SA; agents [A]) and egress (pipeline) on status and dry-run spec, YAML mirroring the Terraform rules (scratch/run6-day2/2-4-*.yaml). tfvars already hold the same values, so a Terraform plan after the wait is the drift check.
- 05:24:51Z wait over. T13 `outside-read` (run-6): stage PASS. T14R `post`: ABORT by its guard (needs the operator ingress rule; no verdict). **Run-order error found:** RUN-ORDER-run6 2-3 listed T14R `post` with no ingress rules, but the script (and run-3) needs operator ingress without the agent rule. **Change:** 2-4 split into 2-4a (gcloud: operator ingress incl. T39b control SA + T39b egress; wait 15; T14R `post`) and 2-4b (gcloud: agent ingress [A] added; during its wait T13 `copy`, T22 `enforced`, T39, T39b, which agent ingress does not affect; after it T23 `post`). Agent A's tfvars ingress stays set; the Terraform drift check runs after 2-4b.
- 2-4a applied by human (gcloud, separate shell; verified 05:30:57Z): status and spec = 3 projects, ingress [operator: operator user + T39b control SA], egress [storage buckets.list + serviceAccounts.getOrCreate to the seed]. Wait 15 counted from 05:31Z (apply time not seen) until ~05:46Z.
- 05:46Z T14R `post` (run-6): INCONCLUSIVE (as run-3): query exit 0 but no function response; agent reply body holds a VPC-SC 403 (SECURITY_POLICY_VIOLATED), i.e. agent A's own API call refused without the agent ingress rule. The docs claim (internet access kept) is not tested by this, as pre-registered.
- 2-4b applied by human (gcloud; verified 05:51:46Z): status and spec ingress [operator, agents], egress 1. Wait 15 until ~06:07Z; during it T13 `copy`, T22 `enforced`, T39, T39b.
- T13 `copy` (run-6): stage PASS. T22 `enforced` (run-6): FAIL, same as run-5-r2: one plan error, module.prj_outside GCS service-account lookup (getOrCreate) refused; audit log: egress violation, source data (tooling quota project), target outside project, RESOURCES_NOT_IN_SAME_SERVICE_PERIMETER; read exit 0; violations naming the tooling quota project 0.
- T39 `split` (run-6): stage PASS (inside stack, data quota project: plan exit 2; outside stack, seed quota project: plan exit 2; enforced violations naming either quota project 0).
- T39b `egress` (run-6, T39B_OTHER_SA = control SA): stage PASS. Single-stack full plan with the seed as quota project exit 2 under enforcement; enforced violations naming the seed 0; control (same `buckets.list` with the seed as billing project, impersonating the control SA, which has ingress but is not in the egress rule) refused by VPC-SC with 1 enforced egress violation naming the seed. T39 result.json: PASS.
- Observation (T22 vs T39b): the single stack with the in-perimeter quota project (T22) fails on the outside project's service-account lookup (egress data -> outside), while the same stack with the outside quota project plus a 2-method storage egress rule (T39b) plans cleanly.
- 2-4b drift check (untargeted plan, seed quota project, -lock=false; scratch/run6-day2/plan-2-4b-drift.txt): only diff = order of the two operations in the operator ingress rule (storage/aiplatform swapped), status and spec. Same meaning; not applied.
- 2-5 plan: infra/agents plan-run6-stage2-5.tfplan, 1 add (agent B); agent A 'has changed' is a refresh note only (no action). Apply after the 2-4b wait (~06:07Z); A deployed 04:29Z, so the 30-min spacing holds.
- 2-5 applied by human: agent B creation complete ~06:10Z (2m15s). T14 `b` (run-6): stage PASS. T18 `pre` (run-6): stage PASS (agent B's calls work without its own ingress rule, as in v1).
- T23 `post`: ABORT by its guard (no verdict): the script requires both agent identities in the ingress rule; the run-order deviation "[A] only" conflicts with the script. **Change (the fallback named in RUN-ORDER-run6, as run-5 stage 6c):** stage 2-5b, gcloud (human): agents ingress [A, B] on status and spec (scratch/run6-day2/2-5b-ingress.yaml; tfvars updated to match). Wait 15, then T23 `post`, before 2-6 (the deny policy would affect B's calls).
- 2-5b applied by human (gcloud; verified 06:15:41Z): agents ingress 2 identities on status and spec. Earliest T23 `post`: 15 min after 06:15:41Z. **Paused by the human at 06:15:41Z.** Running paid resources: agents A and B (destroy today in 2-8).
- 06:59Z resumed. T23 `post` (run-6): PASS (pre: A tool 200; post: A tool 200; B tool URLError Network is unreachable).
- 2-6 plan: infra plan-run6-stage2-6.tfplan, -target=google_iam_deny_policy.dc1_agents_predict: 1 add; dc1_approved_agent_principals updated to the current agent A (the old value was an earlier run's A). Wait 10 after apply.
- 2-6 applied by human (~07:03:12Z): deny policy lzv-dc1-deny-agent-predict on the runtime project, exception [A]. Wait 10 until 07:13:12Z.
- 2-6b plan (prepared during the 2-6 wait; -var enable_dc1_deny=false -var enable_v2_folder_deny=true, tfvars unchanged until T18 post): infra plan-run6-stage2-6b.tfplan, targeted at both deny policies: 1 destroy (project deny), 1 add (folder deny lzv-v2-deny-agent-predict, exception [A]). **Run-order conflict found:** the folder deny denies predict to every org agent except A, so agent C (2-7, T33/T34) would be refused; a step 2-6c (folder deny off, wait 10) is needed before agent C's queries.
- 07:13Z T18 `post` (run-6): PASS (B refused PERMISSION_DENIED; A answered; policy age 621s). tfvars set to the 2-6b values (enable_dc1_deny=false, enable_v2_folder_deny=true).
- 2-6b apply attempt 1 (human, ~07:16Z): project deny destroyed; folder deny create FAILED: 'display name length (70) is longer than the maximum allowed length (63)' (infra fault, no test ran). Fixed in infra/v2-org.tf (57 chars). Re-plan plan-run6-stage2-6b-r2.tfplan: 1 add (folder deny only). Since ~07:16Z no deny policy is in place.
- 2-6b-r2 applied by human (~07:47:09Z): folder deny lzv-v2-deny-agent-predict on fldr-lz-validation, exception [A]. Wait 10 until 07:57:09Z.
- 2-7 plan (prepared during the T37 wait; -var enable_v2_folder_deny=false swp_enabled=true enable_v2_psci=true): infra plan-run6-stage2-7.tfplan, targeted at the deny policy, SWP (APIs, VPC, subnets incl. lzv-swp-psci, routes, firewall, gateway, policy, rule) and PSC-I (network attachment lzv-psci, aiplatform service identity, networkAdmin grant): 20 add, 1 destroy (folder deny = stage 2-6c merged into 2-7, one wait). Perimeter excluded (its only diff is the operations order).
- agent C source built locally (tests/fixtures/agent_c/build.sh -> infra/agents/build/source-c.tar.gz).
- 07:57Z T37 (run-6): PASS (Enforced): agent B refused PERMISSION_DENIED (deny wording present), agent A answered, folder policy age 623s, project policy absent. tfvars set to the 2-7 values.
- 2-7 applied by human (~08:00:25Z): 20 add (SWP gateway lzv-swp, proxy http://10.77.0.10:443, PSC-I attachment lzv-psci), folder deny destroyed. Agent C queries not before 10 min after 08:00:25Z.
- T16 (run-6): PASS (allowed host via proxy 200; non-allowed host 403 on CONNECT; gateway_requests DENIED entry present; bypass timed out, not DNS). 3 Cloud Run jobs left for the human to delete (lzv-t16a/b/c-run6-*).
- 2-7c plan: infra/agents plan-run6-stage2-7c.tfplan: 2 add (agent C reasoning engine with network_attachment lzv-psci and PROXY_SERVER_URL; terraform_data inputs). Agent B 'has changed' = refresh note. B deployed ~06:10Z, so the 30-min spacing holds.
- 2-7c applied by human: agent C creation complete 08:44Z (4m15s). T33, T34: ABORT by their guard (no verdict): output v2_psci_attachment_name empty. Cause: the targeted 2-7 apply does not write outputs whose value has no targeted dependency (this one is the constant "lzv-psci"). Fix: `terraform apply -refresh-only` (human); preview: 34 state syncs (IAM etags, computed fields of the new SWP/VPC resources), no resource changes, output v2_psci_attachment_name added.
- refresh-only apply by human (saved plan plan-run6-refresh-only.tfplan; the interactive form cannot answer 'yes' in the ! shell): 0/0/0, output v2_psci_attachment_name written. T33, T34 started ~08:59Z.
- T33 (run-6): PASS (Enforced): agent C (PSC-I) via the SWP: allowed host 200; www.wikipedia.org refused on CONNECT (403); gateway_requests DENIED entry names wikipedia.
- T34 (run-6): INCONCLUSIVE (as pre-registered for a missing log): control via proxy 200; direct connection to example.com failed (NewConnectionError, not DNS), but no firewall log DENIED entry for lzv-swp-deny-egress-all from 10.77.4.0/28 in ~10 min. Follow-up read (Opus): the rule has logging on (INCLUDE_ALL_METADATA, egress, prio 65000, deny all), and the runtime project has NO firewall log entries at all in the last hour. So the agent's direct packets most likely never reach the VPC (the PSC interface does not carry the agent's default internet route); the failure cannot be attributed to the firewall rule. Not retried.
- 2-8a plan: infra/agents plan-run6-stage2-8a.tfplan: destroy agents A, B, C (+ agent C inputs), 4 destroy.
- 2-8a applied by human: agents A, B, C destroyed (4 destroy). No paid agents left.
- 2-8b plan (untargeted, tfvars reset: vpc_sc_enforced=false, no operator/agent/extra ingress, pipeline egress null, swp off, psci off, tooling_quota_project null; deny toggles already off): infra plan-run6-stage2-8b.tfplan: 20 destroy (SWP, VPC, PSC-I attachment, firewall, APIs, networkAdmin grant), 1 change (perimeter: status removed; ingress and egress removed from spec; spec keeps 3 projects).
- 2-8b applied by human: 20 destroy, perimeter reset (1 change). Checks after: infra and infra/agents untargeted plans "No changes"; perimeter lzv_ai spec 3 projects, status 0, no ingress/egress; no deny policies on the runtime project or the folder; 0 reasoning engines; 0 Cloud Run jobs in the runtime project (the job subnet deleted cleanly, unlike run-5).

### Day 2 summary (2026-10-28)

14 tests with a run-6 result: 10 PASS (T11, T13, T14, T16, T18, T19, T23, T33, T37, T39 incl. T39b), 2 FAIL (T12, T22: same findings as earlier runs), 2 INCONCLUSIVE (T14R as run-3; T34, no firewall log entry at all).
New observations: T12 analyzer now finds the path (1) and the control query returns 19; T39b egress rule had to be storage (2 methods), not serviceusage (E2.10); T34 the agent's direct traffic leaves no VPC firewall log.
Run-order and infra faults fixed during the day (no verdict affected): agent A started ~11 min before the 2-0 wait ended (deviation); 2-4 Terraform plan refused before operator ingress -> gcloud, split 2-4a/2-4b (T14R post needs operator ingress); T23 post needs [A, B] (fallback 2-5b); T37 deny display name over 63 chars; folder deny removal merged into 2-7 (agent C needs predict); targeted apply skipped a constant output (refresh-only apply).
Still open: T29 FAIL (day 1). Day 3 (gateway) not started. Teardown items in RUN-ORDER-run6 "After run-6".

## Day 3 (2026-10-28)

- 3-0 precheck 09:19Z: seed project has networkservices, networksecurity, agentregistry, iap, modelarmor enabled. Runtime project: agentregistry and iap OFF (preflight gateway names the runtime registry). Stage 3-0a plan: infra plan-run6-stage3-0a.tfplan, -target=google_project_service.v2_gw (-var enable_v2_gateway=true, enable_v2_model_armor=true): 7 API enablements in the runtime project (disable_on_destroy=false), free. Then the gateway preflight.
- 3-0a applied by human: 7 APIs enabled in the runtime project.
- Gateway preflight (human, setup.sh preflight): create ACCEPTED in europe-west1 (lzv-gw-preflight, updateTime 09:26:50Z). Area B is testable in the EU region. Human runs teardown.sh preflight.
- 3-0b plan (untargeted; enable_v2_gateway=true, enable_v2_model_armor=true; floors off): infra plan-run6-stage3-0b.tfplan: 17 add (Agent Gateway lzv-gw, registry entries for the MCP fixture and two Google endpoints, IAP and Model Armor authz extensions and policies, Model Armor templates lzv-ma-gw and lzv-ma-pi, image repo lzv-gw, dep service agent and its 3 roles, registry egress grant), 0 change, 0 destroy.
- teardown.sh preflight (human, ~09:29Z): DELETE accepted (HTTP 200). 09:31Z: GET still 200; the delete operation for lzv-gw-preflight is running (not done, no error). Re-check later.
- 3-0b applied by human: 15 of 17 created (gateway lzv-gw, registry entries, Model Armor extension + policy, templates, repo, dep agent + roles, egress grant). FAILED: IAP authz extension: 400 "iapPolicyVersion is a required key to be specified in metadata for IAP AuthzExtension with unspecified load balancing scheme"; the IAP authz policy (depends on it) not created. Infra fault, no test ran.
- Fix (Opus decision): metadata.iapPolicyVersion = "V1" in infra/v2-gateway.tf. Docs (delegate-authorization, fetched 2026-10-28) show "V2" in the sample and "strongly recommend" V2 (IAM Unified Access Policy, set up as separate policies, may need constraints/iam.managed.disableAccessPolicyBindings off); V1 = the legacy IAM allow policy, which is what the approved E3 design uses (roles/iap.egressor on the registry). So T31 tests V1; **V2 is not tested (limitation)**. Re-plan plan-run6-stage3-0b-r2.tfplan: 2 add (IAP extension, IAP authz policy).
- MCP fixture build (setup.sh build): attempt 1 refused, HTTP 412 "'us' violates constraint 'constraints/gcp.resourceLocations'" (default staging bucket in 'us', as T10 run-1). Fixed in setup.sh: `--default-buckets-behavior=regional-user-owned-bucket` (bucket <runtime>_europe-west1_cloudbuild; teardown note updated). Attempt 2: SUCCESS (build 617a0746, 13s).
- setup.sh deploy: lzv-mcp-reg and lzv-mcp-unreg deployed (internal ingress, IAM invoker, Binary Auth default); roles/run.invoker for the runtime agent principalSet accepted by Cloud Run IAM (rc=0; was UNVERIFIED).
- Agent G source built (agent_g/build.sh). Stage 3-0g plan: infra/agents plan-run6-stage3-0g.tfplan: 2 add (agent G with agent_gateway_config -> lzv-gw; inputs).
- 3-0b-r2 applied by human: IAP authz extension (iapPolicyVersion V1) and IAP authz policy created. The gateway setup is complete.
- Preflight gateway lzv-gw-preflight: GET HTTP 404 at 09:47Z (deleted).
- 3-0g applied by human: agent G creation complete ~09:51Z (4m25s), behind lzv-gw. Agent B redeploy not before ~10:22Z (30-min spacing).
- 3-0d plan: infra plan-run6-stage3-0d.tfplan, -target=google_iam_deny_policy.dc1_agents_predict: 1 add (project deny, T18 form, exception [G]). Wait 10 after apply.
- 3-0d applied by human (~09:53:44Z): project deny, exception [G]. Wait 10 until 10:03:44Z.
- 3-0b(B) plan: infra/agents plan-run6-stage3-0bB.tfplan: 1 add (agent B, not an exception). Apply not before ~10:22Z.
- 10:03Z T30 (run-6): INCONCLUSIVE; T32 (run-6): INCONCLUSIVE. Both controls (registered_echo) got no tool result: agent G's query returned `PERMISSION_DENIED` "Egress request is not authorized ... roles/iap.egressor ... authzPolicy". Opus diagnosis (read-only): gateway_requests log shows 4 × 403 for `https://europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/N/locations/europe-west1/reasoningEngines/<G>/sessions` (the ADK session service, mTLS regional host), agent log "The endpoint is either incorrect or unregistered in the Agent Registry. Only registered endpoints are allowed." The registry held only https://aiplatform.googleapis.com and https://logging.googleapis.com. Docs (scale/runtime/agent-gateway-runtime-deploy, fetched 2026-10-28): "Hostname matching in Agent Gateway is exact", every standard/regional/mTLS variant the SDK uses must be registered. The 4 policy-log entries at the same time are dry-run perimeter records only (dryRun=true).
- Fix (fixture setup, infra fault; expected results unchanged): two registry entries added in infra/v2-gateway.tf: lzv-ep-sessions (https://europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/N/locations/europe-west1/reasoningEngines) and lzv-ep-aiplatform-mtls (https://aiplatform.mtls.googleapis.com). Kept narrow so T31's blocked endpoint (europe-west1-aiplatform.googleapis.com, no mTLS) stays unregistered. Plan plan-run6-stage3-0e.tfplan: 2 add. After apply: wait ~4 min (registry), re-run T30 and T32 as run-6-r2.
- 3-0e applied by human (~10:11:16Z): lzv-ep-sessions and lzv-ep-aiplatform-mtls registered. Registry wait ~5 min.
- 10:16Z T30 re-run (run-6-r2): INCONCLUSIVE again. Gateway log now: IAP policy ALLOWED, Model Armor policy ALLOWED, request to europe-west1-aiplatform.mtls.googleapis.com/.../sessions answered **401 UNAUTHENTICATED** upstream ("Request had invalid authentication credentials"). Gateway log mtls block: clientCertPresent=true, clientCertChainVerified=false, clientCertError=client_cert_validation_not_performed; enforcedGatewaySecurityPolicy.requestWasTlsIntercepted=true. Reading (Opus): the gateway terminates the agent's mTLS and the certificate-bound agent token no longer matches upstream. T32 r2 not run.
- Human decision (AskUserQuestion, 10:2xZ): retry in the documented order: register the essential endpoint list first, then redeploy agent G so it binds after the registrations; re-run as run-6-r3; agent B 30 min after G for T31; if the 401 persists, record it as a finding.
- 3-0f plan: infra plan-run6-stage3-0f.tfplan: 16 add (essential endpoints, standard + mTLS: agentregistry, logging-mtls, telemetry, cloudtrace, monitoring, secretmanager, cloudresourcemanager, iamcredentials, aiplatform.europe-west1.rep, europe-west1-aiplatform.mtls). **Deviation from the doc list:** europe-west1-aiplatform.googleapis.com not registered (T31's blocked endpoint).
- 3-0g2 plan: infra/agents plan-run6-stage3-0g2.tfplan (-var deploy_agent_b=false, -replace agent G): 1 add, 1 destroy. G's new engine ID requires a deny-exception update (3-0h, wait 10) before the tests.
- 3-0f applied by human (~10:20Z): 16 essential endpoints registered. G redeploy not before ~4 min later (registry propagation before binding).
- 3-0g2 applied by human (started after ~10:25Z, after the registry wait): old G destroyed (2m13s), new G created, complete ~10:34Z (5m05s), engine id ending ...468288. Agent B not before ~11:04Z.
- 3-0h plan: infra plan-run6-stage3-0h.tfplan, -target deny policy: 1 in-place update (exception -> new G). Wait 10 after apply, then T30/T32 run-6-r3.
- 3-0h applied by human (~10:35:54Z): deny exception = new G. Wait 10 until 10:45:54Z.
- 10:46Z T30 (run-6-r3): INCONCLUSIVE, same 401 UNAUTHENTICATED on the agent's session call ("Request had invalid authentication credentials") after the documented order (essential endpoints registered, ~4 min wait, then G redeployed and bound). T32 (run-6-r3): INCONCLUSIVE (same control failure). T31 (run-6): INCONCLUSIVE (allowed-endpoint control not answered; part 2 not run: agent B not deployed, Opus decision: part 1 cannot run and part 2 repeats T18; saves a paid deploy).
- **Finding (area B, run-6):** an Agent Runtime agent (ADK, Agent Identity) bound to an Agent Gateway in europe-west1 cannot complete any query: the gateway authorises its calls (IAP V1 policy ALLOWED, Model Armor policy ALLOWED, registry match), intercepts TLS (requestWasTlsIntercepted=true, client cert present but not validated), and Vertex AI answers 401 UNAUTHENTICATED to the forwarded session call. Reading (not verified): the agent's certificate-bound token is not accepted once the gateway re-originates the connection. Tests T30, T31, T32 could not reach their attempts; no claim about gateway tool authorisation, model-path blocking or Model Armor on egress is made from run-6. Not tested: iapPolicyVersion V2; other regions; Gemini Enterprise egress mode.
- 3-2 reset start: teardown.sh run: both MCP Cloud Run services DELETE HTTP 200. Plans: 3-2a infra/agents plan-run6-stage3-2a.tfplan (destroy agent G, 2 destroy; B never deployed on day 3); 3-2b infra plan-run6-stage3-2b.tfplan (43 destroy: gateway, IAP and Model Armor extensions/policies, 21 registry entries, templates, image repo, dep agent roles, egress grant, project deny policy, gateway APIs). Apply 3-2a first (agent bound to the gateway).
- 3-2b applied by human: 27 destroyed, then FAILED: 'There is another ongoing operation for the same AgentGateway' (parallel authz policy deletes). Re-plan plan-run6-stage3-2b-r2.tfplan: 16 destroy (incl. gateway, Model Armor policy/extension, remaining registry entry, template, dep roles, APIs). Apply with -parallelism=1.
- 3-2b-r2 applied by human with -parallelism=1: 16 destroyed. Checks after: infra and infra/agents untargeted plans "No changes"; perimeter lzv_ai dry-run (spec 3, status 0, no ingress); no deny policies on the runtime project or the folder; 0 reasoning engines; 0 agent gateways; 0 Cloud Run services. Open: Cloud Build staging bucket gs://<runtime>_europe-west1_cloudbuild (one fixture source upload) awaits the human delete.

### Day 3 summary (2026-10-28)

Agent Gateway create accepted in europe-west1 (preflight). T30, T31, T32: INCONCLUSIVE (finding above: agent bound to the gateway gets 401 UNAUTHENTICATED upstream after the gateway authorises and intercepts TLS; persisted after registering the essential endpoints and redeploying G in the documented order). Infra/fixture faults fixed during the day: IAP extension needs metadata.iapPolicyVersion (V1 chosen, V2 not tested); Cloud Build default staging bucket in 'us' refused by gcp.resourceLocations (regional bucket); exact-hostname registry entries (sessions mTLS host, essential endpoints, minus T31's blocked host); gateway allows only one operation at a time (reset re-applied with -parallelism=1).

### Run-6 summary (2026-10-27 to 2026-10-28)

38 test results: 30 PASS, 3 FAIL (T12, T22: same findings as earlier runs; T29: block worked, message prefix differs), 5 INCONCLUSIVE (T14R as run-3; T34 no firewall log; T30, T31, T32 gateway 401). Environment reset: no drift in either stack; perimeter dry-run without rules; no agents, gateways, deny policies or jobs. Remaining teardown (RUN-ORDER-run6 "After run-6"): operator org-level roles/modelarmor.floorSettingsAdmin and roles/iam.denyAdmin; T39b control SA; floor settings exist non-enforcing; Cloud Build staging bucket.
- Cloud Build staging bucket: 404 at 11:42Z (already deleted by the human).
- Human decision 2026-10-28: the operator keeps the org-level `roles/modelarmor.floorSettingsAdmin` and `roles/iam.denyAdmin`, and the T39b control service account (no keys) is kept for run-7. These are not removed at teardown. The floor settings stay in place, non-enforcing.

## Redaction (2026-10-28)

- tools/redact.py run in place on the run-6 evidence (195 files, 150 changed) and on this log; `--check` 0 findings.
- redaction-checker (independent scan, 200 files): FAIL with 5 items, resolved by Opus: (1) 592 service-account emails: all placeholders (service-PROJECT_NUMBER_n, SA_n) at `PROJECT` or Google service-agent domains, no action; (2) vpcServiceControlsUniqueIdentifier values: per-request references, already kept in committed run-1..run-5 evidence, no action; (3) 12-digit `projectIdOrNum` in T33/T34 (PSC attachment consumer, Agent Runtime tenant project): redact.py pattern added (tests 8/8 OK), T33/T34 re-redacted; (4) KMS paths use placeholders, T25 line 103 is a note; (5) digit-only hashes, false positives. infra/v11-swp.tf "public_ip" is Google's documented private.googleapis.com range (out of scope).
- Final: `--check` on 196 files 0 findings; no raw org ID, project numbers, project IDs, domain or seed ID in scope.
