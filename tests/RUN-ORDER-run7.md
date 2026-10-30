# Run-7 order: all tests, second run of v2 (DRAFT)

Status: draft, 2026-10-28. Built from [RUN-ORDER-run6.md](RUN-ORDER-run6.md) plus every order change and fixture fix found during run 6 ([run-6.md](../evidence/runs/run-6.md)). Nothing has been applied.

Purpose: the second run of the v2 tests (EXECUTION-PLAN E5 item 4), and the fourth run of v1/v1.1. Expected results are unchanged for every test (scripts' `header` text as committed). Area B (T30–T32) runs with a changed setup (see "Gateway changes"); report it as "with agent token binding turned off, IAP policy V2".

Run ID: `run-7` for every test; retries `run-7-rN`. Rules as in run 6:
- The human applies every plan and runs every gcloud change; Opus prepares saved plans (`-out=plan-run7-stageX.tfplan`) and runs the tests.
- Pacing: one agent deploy at a time, 30 minutes apart, no rapid retries, stop on `CONSUMER_SUSPENDED`.
- Paid resources (agents, Secure Web Proxy, gateway) are created and destroyed the same day.
- Logins: fresh `gcloud auth login` and `gcloud auth application-default login` before each batch of applies. Admin logins expire after about an hour; an expired ADC login mid-apply gives `invalid_grant ... invalid_rapt` and leaves the saved plan stale (run-6 1-0a).
- Waits: 15 minutes after org-policy and perimeter changes, 10 after deny policies (and the IAP V2 policy), about 4 after Agent Registry changes.
- Org-scope toggles are applied alone, one per apply.
- Saved plans only: the interactive `yes` cannot be answered from the `!` shell (use `-out` and apply the file, including refresh-only).

## Before day 1 (status 2026-10-28)

| # | Item | Status |
|---|---|---|
| P1 | KMS: version 1 of `lzv-build-key` (runtime) and `lzv-attestor-key` (mcp) restored and enabled by the human | Done 2026-10-28, both `ENABLED` (checked). Rings and keys are out of state; 1-0a and 1-3a import them (`p2_import_existing_kms=true`) |
| P2 | Operator roles: org-level `roles/modelarmor.floorSettingsAdmin` and `roles/iam.denyAdmin` kept (human decision 2026-10-28); `roles/iam.accessPolicyAdmin` on the runtime project (IAP V2) | Done 2026-10-28 (checked) |
| P3 | T39b control service account `lzv-t39b-control@…` kept with its roles (no keys) | Done |
| P4 | T19: the `agentDefaultAccess` binding is already in the runtime project (F14); `added=0` is accepted and recorded, as in run 6 | Carried over from run 6 (human decision 2026-10-27); the human may change it before day 2 |
| P5 | `T04_DENIED_MODEL=gemini-4-argon`, `T04_LOCATION=global` (same as runs 1, 2, 5, 6) | Record in run-7.md before day 1 |
| P6 | Model Armor floor settings (org, folder, runtime project) still exist in GCP, non-enforcing (F20). A Terraform create updates the existing floor (run-6 observation) | Check the plan in 1-0a/1-2: expect create, no error |
| P7 | `terraform init` done in `infra/`, `infra/agents`, `infra-split/inside`, `infra-split/outside` | Check `.terraform` exists |
| P8 | Org policy for IAP V2: `iam.managed.disableAccessPolicyBinding` (singular) effective `enforce: false` on the runtime project | Checked 2026-10-28; re-check on day 3 |

## Day 1: policies, Model Armor, organization scope (no agents)

Perimeter in dry-run with the runtime project in the spec (base state).

| Stage | Apply before (human), then wait | Tests (`RUN_ID=run-7`) | During the wait |
|---|---|---|---|
| 1-0a | Project scope, one apply: `p2_import_existing_kms=true` with `enable_dc3_build_bucket=true` (imports DC3 ring and key), `enable_dc4_sink=true`, `enable_v2_model_armor=true`. No wait | — | — |
| 1-0b | Org scope, alone: `t36_mode="dryrun"`. No wait before 1-1 (a dry-run policy blocks nothing) | — | — |
| 1-1 | none | T01, T02, T03, T17, T04, T08, T09, T06 `before`, T13 `setup`, T13 `dryrun`, T15, T24, T28; last, at least 15 min after 1-0b: T36 `dryrun` | — |
| 1-2 | One apply: `enable_t05_policy`, `enable_t06_policy`, `enable_t07_policy`, `enable_v2_ma_folder_floor`, `enable_v2_ma_vertex` = true. Apply only after T36 `dryrun` finishes. Wait 15 | T05, T06 `after`, T07, T10, T20, T21, T27, T29 | Nothing that creates buckets or Cloud Build runs |
| 1-3a | Targeted, one apply: T05/T06/T07 off (`-target=module.folder_root`); `v2_ma_floor_enforce = { folder = false }` (`-target=google_model_armor_floorsetting.v2_folder`); T25 first part (`enable_t25_binauthz=true`, targets: `google_project_service.t25`, `module.t25_kms`, `module.t25_binauthz[0].google_container_analysis_note.notes`, `module.t25_binauthz[0].google_binary_authorization_attestor.attestors`; imports the T25 ring and key; no policy yet, F12). No wait | — | — |
| 1-3b | Org scope, alone, targeted at the three T36 resources: `t36_mode="enforce"` | — | — |
| 1-3c | Org scope, alone, targeted: `enable_v2_ma_org_floor=true`. Wait 15 after this apply | T36 `enforce`, T38 | — |
| 1-4 | Targeted `module.t25_binauthz`: Binary Authorization policy. No wait (not an org policy) | T25; human deletes the T25 Artifact Registry repository | — |
| 1-5 | Reset, four applies: (a) full plan, project scope: T25, DC3, DC4, KMS out of state, project floor enforcement off; check mcp default rule `ALWAYS_ALLOW`; (b) org scope alone: `t36_mode="off"`; (c) org scope alone: org floor enforcement off; (d) untargeted: floor toggles off, Model Armor template and APIs. Then an untargeted plan: "No changes" | — | — |

While T36 is enforced (1-3b to 1-5b), every new bucket in the organization needs the label `lzv-org-test`: no bucket-creating apply or test in between (T25 writes to the existing DC3 bucket only).

Notes: T17 runs before T25 is on. T08, T09 and T13 `setup` run before T07 is on. T10 and T21 need T07 on. After 1-5a the KMS versions are scheduled for destruction again; a later run needs P1 again (30-day window).

## Day 2: perimeter, agents, deny policies, egress (paid: agents, Secure Web Proxy)

Perimeter changes before operator ingress exists are made with gcloud (Terraform plans are refused by VPC-SC until the operator has ingress). Rule YAML files: copy `scratch/run6-day2/2-4-egress.yaml`, `2-4a-ingress.yaml`, `2-4b-ingress.yaml`, `2-5b-ingress.yaml` to `scratch/run7-day2/` and replace the agent identities with the run-7 engine IDs (A and B are new deploys). Update `terraform.tfvars` to the same values at each step so later Terraform plans show no perimeter drift (the only accepted diff is the order of operations in the operator rule).

| Stage | Apply before (human), then wait | Tests | During the wait |
|---|---|---|---|
| 2-0 | gcloud: remove the runtime project from the dry-run spec. Wait 15 | — | T19 `before` (IAM reads only) |
| 2-1 | infra/agents: `deploy_agent_a=true`. Apply **after** the 2-0 wait (run 6 started 11 min early, a deviation) | T19 `after`, T11, T12, T14 `a`, T14R `pre`, T23 `pre` | — |
| 2-2 | infra, full plan: runtime back in the dry-run spec; `tooling_quota_project=<data>`. Wait 15 | T22 `dryrun` (after the wait) | — |
| 2-3 | infra, `-target=module.vpc_sc`: `vpc_sc_enforced=true`, no ingress rules. Wait 15 | T13 `outside-read` | — |
| 2-4a | gcloud (status and dry-run spec): operator ingress (operator + T39b control SA) and the T39b egress rule (Cloud Storage: `google.storage.buckets.list`, `google.storage.projects.serviceAccounts.getOrCreate`, to the seed project). Wait 15 | T14R `post` (operator ingress, no agent rule) | — |
| 2-4b | gcloud: ingress operator + agents [A]. Wait 15. Then an untargeted Terraform plan (data quota project) as the drift check | T23 `post` moves to 2-5b | T13 `copy`, T22 `enforced`, T39, T39b |
| 2-5 | infra/agents: `deploy_agent_b=true` (at least 30 min after A) | T14 `b`, T18 `pre` | — |
| 2-5b | gcloud: agents ingress [A, B] (T23's script needs both identities). Wait 15 | T23 `post` (before 2-6: the deny policy affects B) | — |
| 2-6 | infra, targeted at the project deny policy: `enable_dc1_deny=true`, exception [A] (set `dc1_approved_agent_principals` to the run-7 A). Wait 10 | T18 `post` | Prepare 2-6b |
| 2-6b | infra, targeted at both deny policies: project deny off, folder deny on (`enable_v2_folder_deny=true`, exception [A]; display name fixed in run 6). Wait 10 | T37 | Prepare 2-7; build agent C source (`tests/fixtures/agent_c/build.sh`) |
| 2-7 | infra, one targeted apply: folder deny off (agent C needs predict), `swp_enabled=true`, `enable_v2_psci=true`. Then a **saved refresh-only plan** applied by the human, so the constant output `v2_psci_attachment_name` is written (targeted applies skip it). Agent C queries not before 10 min after the folder deny removal | T16; human deletes the 3 Cloud Run jobs | — |
| 2-7c | infra/agents: deploy agent C (PSC-I, proxy URL; at least 30 min after B) | T33, T34 | — |
| 2-8 | Reset: (a) infra/agents: destroy A, B, C; (b) infra untargeted with tfvars reset (`vpc_sc_enforced=false`, no ingress/egress, `tooling_quota_project=null`, SWP and PSC-I off, deny toggles off). Checks: both stacks "No changes"; perimeter spec 3 projects, status 0, no rules; no deny policies; 0 reasoning engines; 0 Cloud Run jobs | — | — |

T34: run 6 found no firewall log entry at all for the agent's direct traffic (F18). The expected result is unchanged, so T34 is likely INCONCLUSIVE again; run it as written and record the result.

## Day 3: Agent Gateway (paid: gateway, agents)

### Gateway changes for run 7 (human decision 2026-10-28; fixtures only)

1. Agent G opts out of the default token binding: `infra/agents` var `agent_g_caa_token_binding_opt_out` (default true) sets `GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=False` (Google's gateway deploy samples; run-6 401, F16; `notes/doc-verification-v2-B-401.md`).
2. Agent G packages pinned: `google-cloud-aiplatform` 2.6.0, `google-adk` 2.13.0.
3. IAP policy V2: `infra` var `v2_gateway_iap_policy_version` (default "V2"): access policy `lzv-gw-egress` (ALLOW `iap.googleapis.com/resources.egressViaIAP` for the agent principalSet, registered destinations in the registry location) and its project binding replace the V1 `roles/iap.egressor` grant (`notes/doc-verification-v2-B-iapv2.md`).

Already in `infra/v2-gateway.tf` from run 6: `metadata.iapPolicyVersion`, the sessions mTLS host and `aiplatform.mtls` registry entries, the 16 essential endpoints (without `europe-west1-aiplatform.googleapis.com`, T31's blocked host). Already in `setup.sh`: the regional Cloud Build staging bucket.

| Stage | Apply before (human), then wait | Tests |
|---|---|---|
| 3-0 | Precheck (read-only): APIs on the seed (networkservices, networksecurity, agentregistry, iap, modelarmor) and on the runtime project (left enabled by run 6, `disable_on_destroy=false`); P8 org policy. Gateway region preflight is skipped: run 6 showed the create is accepted in europe-west1 (record this) | — |
| 3-0a | infra, untargeted: `enable_v2_gateway=true`, `enable_v2_model_armor=true` (gateway, registry entries, IAP extension V2 + access policy + binding, Model Armor extension and templates). Apply with **`-parallelism=1`** (the gateway takes one operation at a time). Check the access policy and binding exist (`gcloud iam access-policies list` / `gcloud iam policy-bindings list`, `--location=global`, runtime project) | — |
| 3-0b | `tests/fixtures/gateway/setup.sh build` and `setup.sh deploy` (MCP fixture: registered, unregistered, injection) | — |
| 3-0c | Build agent G (`tests/fixtures/gateway/agent_g/build.sh`, pinned packages). infra/agents: `deploy_agent_g=true`, at least 4 min after 3-0a (registry before binding). Check (read-only) that the engine's env vars include the opt-out | — |
| 3-0d | infra, targeted: project deny policy (T18 form), exception [G] (the run-7 G engine). Wait 10 (also covers the V2 policy wait) | — |
| 3-1 | none | T30, T32, T31 part 1 |
| 3-1b | Only if T30's registered-tool control answered: infra/agents `deploy_agent_b=true`, at least 30 min after G (not an exception in the deny policy) | T31 part 2 |
| 3-2 | Reset: `teardown.sh run`; infra/agents destroy G (and B); infra with gateway and deny off, **`-parallelism=1`**. Human deletes the Cloud Build staging bucket `gs://<runtime>_europe-west1_cloudbuild`. Checks: both stacks "No changes"; 0 gateways, 0 reasoning engines, 0 Cloud Run services; no access policy or binding `lzv-gw-egress`; no deny policies | — |

Stop rule for area B: if T30's registered-tool control still fails (401 or any upstream refusal), record T30–T32 INCONCLUSIVE with the gateway log, skip 3-1b (no agent B deploy), and go to 3-2. No further retries that day. If the IAP V2 policy refuses the registered tool (403 from IAP), that is a fixture fault: record it, one fix allowed (for example the condition expression), then the same stop rule.

## After run-7

- Redact the evidence (`tools/redact.py`, then the redaction-checker), commit, update the reports: v2 results from two runs; T30–T32 labelled with the run-7 setup.
- Human decisions: keep or remove the org-level operator roles, `roles/iam.accessPolicyAdmin` on the runtime project, and the T39b control SA; KMS versions are scheduled for destruction again after 1-5a.
- The public copy.
