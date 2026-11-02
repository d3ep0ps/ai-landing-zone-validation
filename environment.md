# Reference environment

Source: `evidence/environment/snapshot/` (redacted), `evidence/supplement/policy-sources-2026-10-25.txt`, `notes/tool-versions.txt`, `infra/*.tf`, `tests/RUN-ORDER.md`. Identifiers appear as placeholders (`ORG_ID`, `FOLDER_ID_n`, `PROJECT_n`, `ACCESS_POLICY_n`). Results are in [results.md](results.md); caveats in [limitations.md](limitations.md).

## Hierarchy

```
organization (ORG_ID)
  iam.allowedPolicyMemberDomains (the only org-level policy)
  lzv-org-access-policy-empty (org-level access policy, empty)
  fldr-lz-validation (FOLDER_ID_2)   <- test folder, carries the folder policies
    prj-lzv-mcp        in perimeter lzv_ai
    prj-lzv-data       in perimeter lzv_ai (also holds the locked log bucket)
    prj-lzv-outside    NOT in the perimeter (T13 outside bucket)
    fldr-ai-prod (FOLDER_ID_1)       <- carries vertexai.allowedModels only
      prj-lzv-runtime2 in perimeter lzv_ai (agents, model calls)
```

- Project IDs are `PREFIX-prj-lzv-NAME`. Four projects: runtime, mcp, data, outside. The snapshot lists them as PROJECT_n.
- `prj-lzv-logging` was dropped (billing account limit of 5 linked projects); its log bucket is in `prj-lzv-data`.
- No network project. v1 did not run T16; in v1.1 the Secure Web Proxy resources were placed in the runtime project.
- The runtime project is in `fldr-ai-prod` so that the T04 model allow-list applies to it and not to the other projects.

## Replaced runtime project (run 1)

During run 1 (2026-10-23) Google suspended the first runtime project (`403 CONSUMER_SUSPENDED` on the Vertex AI API). Google's notice said the project "has been suspended because it is associated with repeated Terms of Service violations" and named no specific activity. Before the suspension, one agent deploy had been attempted there and failed to start; the next deploy was refused because of the suspension. On 2026-10-24 the human deleted it and Terraform created a replacement (`prj-lzv-runtime2`) in the same folder, with the same policies and the perimeter spec pointing at the new project number. Tests that ran in the runtime project (T01, T04, T05) were re-run there (`run-1-r2`); T11, T12 and T14 first ran in the replacement. The run-1 results from the first project are kept in `evidence/`. Run 2 and the T14R re-test used the replacement project.

## v1.1 environment (run-4 2026-10-25..26, run-5 2026-10-26..27)

After the v1 teardown, the same Terraform (plus the v1.1 files `infra/v11-*.tf`) rebuilt the environment on 2026-10-25 with a new project prefix. Same hierarchy, project names, folder policies, perimeter and locked log bucket as above; the runtime project is again named `prj-lzv-runtime2`. Base state: all v1.1 toggles off, perimeter dry-run. Design decisions are in `EXECUTION-PLAN.md` Appendix D; the stage order is in [tests/RUN-ORDER-v11.md](tests/RUN-ORDER-v11.md).

| Toggle / setting | Test | What it adds | Where |
|---|---|---|---|
| `enable_t07_policy` | T20 | `gcp.restrictNonCmekServices` for Storage (as v1 T07), stage 1 only | fldr-lz-validation |
| `enable_dc3_build_bucket` | T21, T25 | KMS key ring `lzv-build-keyring`, key and a CMEK regional build staging bucket; `roles/storage.admin` on it for the build service accounts | runtime project (builds run in mcp) |
| `enable_dc4_sink` | T24 | Folder sink `lzv-dc4-admin-activity` (Admin Activity audit logs) to the locked log bucket | test folder to data project |
| `enable_t25_binauthz` | T25 | KMS key ring `lzv-binauthz-keyring`, attestor and note; project Binary Authorization policy `REQUIRE_ATTESTATION` | mcp project |
| `enable_dc1_deny`, `dc1_approved_agent_principals` | T18 | IAM deny policy `lzv-dc1-deny-agent-predict`: denies `aiplatform.googleapis.com/endpoints.predict` to the project agent principalSet, approved agent A as exception | runtime project |
| `tooling_quota_project` | T22 | An in-perimeter project (the data project) as the quota project for Terraform and gcloud, with the APIs Terraform needs enabled there | data project |
| `vpc_sc_enforced`, `vpc_sc_operator_ingress`, `vpc_sc_agent_ingress_identities` | T22, T23 | Perimeter enforced; operator ingress rule; ingress rule for the two agents' `principal://` identities | perimeter `lzv_ai` |
| `swp_enabled` | T16 | Secure Web Proxy, VPC, proxy-only subnet, egress firewall | runtime project; applied 2026-10-26 (run-4) and 2026-10-27 (run-5) for T16, gateway destroyed the same day each time |

Changes made by hand outside Terraform during run-4 (each approved by the human):

- `roles/iam.denyAdmin` granted to the operator at organization level, to create the deny policy (Security Admin does not include it). It stays until teardown.
- Container Analysis API enabled in the seed project, because the Binary Authorization note call was billed to the seed quota project.

Other notes:

- Toggles were applied one stage at a time. T25 stayed on from stage 3 until the end of run-4, because KMS key rings cannot be deleted and re-enabling T25 later would fail on the existing key ring.
- With the perimeter enforced, a full Terraform plan fails with any single quota project (F5 and F9), so stage 10c used a plan targeted at the perimeter module.
- Two agents (A and B) in the runtime project; agent B was destroyed and re-created during the run (stages 8 and 10).
- After run-4 (last successful runtime call 2026-10-25), Google suspended this runtime project too (`CONSUMER_SUSPENDED`). The suspension notice is not in the evidence and no reason is recorded. The human submitted an appeal and Google reinstated the project on 2026-10-26 without giving a reason. T16 then ran; the repeat run (run-5) has not been done.
- Run-5 used the same environment and projects, with no rebuild. Agents were destroyed at the start; the runtime project was removed from the dry-run spec by gcloud (human approved) before agent A was deployed, then put back by Terraform. Agent A and agent B were each deployed once (stages 4 and 6b), more than 30 minutes apart, and destroyed the same day. With the perimeter enforced, the plans were targeted at the module concerned, with the data project as quota project. The run order is in [RUN-ORDER-v11-run5.md](tests/RUN-ORDER-v11-run5.md).
- Run-5 reset (2026-10-27): deny policy, agents, Secure Web Proxy gateway, DC3, DC4 and T25 destroyed; perimeter back to dry-run with no ingress rules; `tooling_quota_project` unset; the mcp Binary Authorization policy is back to `ALWAYS_ALLOW`. The KMS key rings and keys of DC3 and T25 cannot be deleted; Terraform only dropped them from state.

## v2 environment (run-6, 2026-10-27..28; run-7, 2026-10-28..29; run-8 and run-9, 2026-10-30)

Run 6 ran all tests (v1, v1.1, v2) in one order on the existing environment, with the v2 Terraform files added (`infra/v2-*.tf`); order in [tests/RUN-ORDER-run6.md](tests/RUN-ORDER-run6.md), log in [run-6.md](evidence/runs/run-6.md). Hierarchy and projects as above (runtime project `prj-lzv-runtime2` in `fldr-ai-prod`). Policies under test are unchanged; v2 adds the following. Run 7 used the same environment and order ([tests/RUN-ORDER-run7.md](tests/RUN-ORDER-run7.md), log in [run-7.md](evidence/runs/run-7.md)), with the area-B changes listed below the table.

| Item | Test | Value / scope |
|---|---|---|
| Model Armor floor settings | T27, T29, T38 | Org, test folder and runtime project; `pi_and_jailbreak` `MEDIUM_AND_ABOVE`, enforcement on while testing. The project floor has the Vertex AI (`AI_PLATFORM`) integration in `INSPECT_AND_BLOCK`. Templates regional (europe-west1), floor settings global |
| Custom constraint `custom.lzvOrgTestBucketLabel` and org policy | T36 | Organization scope, on `storage.googleapis.com/Bucket`, condition: label `lzv-org-test`; dry-run spec first, then enforced; one exception project (policy with enforce false). Removed the same day |
| Folder deny policy `lzv-v2-deny-agent-predict` | T37 | `fldr-lz-validation`, denies `aiplatform.googleapis.com/endpoints.predict` to all agent identities in the organization trust domain, exception agent A |
| Agent Gateway `lzv-gw` | T30, T31, T32 | europe-west1, with Agent Registry entries (MCP fixture, essential endpoints, exact hostnames), IAP authorization extension (`iapPolicyVersion` V1 in run 6, V2 in run 7) and policy, Model Armor extension and policy, two MCP fixture Cloud Run services (internal ingress, IAM invoker). Agent G bound to it |
| PSC interface | T33, T34 | Network attachment `lzv-psci`, attachment subnet 10.77.4.0/28, in the runtime project; agent C with explicit proxy to the Secure Web Proxy (gateway `lzv-swp`, proxy on a private address, port 443) and deny-all egress rule `lzv-swp-deny-egress-all` with logging |
| Split Terraform stacks | T39, T39b | `infra/` and `infra/agents/` with different quota projects (data project for the inside stack, seed project for the outside stack); T39b egress rule for the pipeline identity: `storage.googleapis.com`, `google.storage.buckets.list` and `google.storage.projects.serviceAccounts.getOrCreate`, to the seed project |
| IAP V2 access policy and binding (run 7) | T30, T31, T32 | Project access policy `lzv-gw-egress` (global) on the runtime project: ALLOW `iap.googleapis.com/resources.egressViaIAP` for the runtime agent principalSet, condition `destination.is_registered == true && destination.agent_registry.location == 'europe-west1'`; project policy binding `lzv-gw-egress` (kind ACCESS). Replaces the run-6 `roles/iap.egressor` grant. Needs `iam.managed.disableAccessPolicyBinding` not enforced on the project (checked: enforce false) |
| Agent G settings (run 7) | T30, T31, T32 | Env `GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=False` (opts out of certificate-bound tokens); `google-cloud-aiplatform[agent_engines,adk]==2.6.0`, `google-adk==2.13.0` |
| APIs | all areas | Agent Registry, IAP, networkservices, networksecurity, Model Armor on the seed (quota) project; the same set on the runtime project for the gateway |

Roles granted by the human for v2: `roles/modelarmor.floorSettingsAdmin` (organization, test folder, runtime project), `roles/modelarmor.admin` (runtime and data projects), `roles/iam.denyAdmin` (organization, from run-4). Human decision 2026-10-28: the organization-level `floorSettingsAdmin` and `denyAdmin` stay with the operator for run-7, and the T39b control service account (no keys) is kept. This differs from E4.5 ("removed at teardown"). Added for run 7: `roles/iam.accessPolicyAdmin` on the runtime project (IAP V2 access policy and binding). All of these remain after run 7, pending a human decision.

Changes made by hand outside Terraform in run 6 (human applied): perimeter ingress and egress rules with gcloud (stages 2-4a, 2-4b, 2-5b; a Terraform plan is refused before the operator has an ingress rule), and the runtime project removed from the dry-run spec before agent A. The perimeter had operator ingress (including the T39b control identity), agent ingress for agents A and B (later), and one egress rule while enforced. The gateway preflight create in europe-west1 was accepted; its delete was complete within about 18 minutes.

Reset state after run 6 (checked 2026-10-28): `infra/` and `infra/agents/` untargeted plans "No changes"; perimeter `lzv_ai` dry-run spec with 3 projects, no enforced status, no ingress or egress rules; no reasoning engines, agent gateways, Cloud Run services or jobs, and no deny policies on the runtime project or the folder; T36 constraint and policies removed. Still present: the three Model Armor floor settings (non-enforcing), the kept organization roles and the T39b control service account, KMS key rings and keys (versions scheduled for destruction again; run-7 needs the restore step). The Cloud Build staging bucket created for the MCP fixture build was deleted by the human.

Run 7 (2026-10-28..29), by hand outside Terraform: the same perimeter rule changes with gcloud (2-4a, 2-4b, 2-5b), a restore of the KMS key versions before day 1, and one refused fixture change on day 3 (Cloud Run ingress `all`, refused by `run.allowedIngress`; nothing changed). The day-3 MCP fixture build used the regional staging bucket.

Run 8 (2026-10-30, area B only): the run-7 area-B setup plus `infra/v2-gateway-vpc.tf` (`enable_v2_gateway_vpc`): VPC `lzv-gw-vpc` in the runtime project, subnet `lzv-gw-attach` 10.77.5.0/28 with Private Google Access, network attachment `lzv-gw-attach` (ACCEPT_AUTOMATIC; one connection endpoint ACCEPTED, 10.77.5.2), PSC endpoint for Google APIs `lzvgwapis` (`all-apis`, 10.77.6.10), private zone `run.app.` with `*.run.app` A 10.77.6.10, and gateway `network_config` (egress attachment, DNS peering for `run.app.`). `dns.googleapis.com` on the seed project is in Terraform state (not gated). Agents G and B; project deny policy with exception G. Reset checked 2026-10-30 08:30Z: both stacks "No changes"; no gateways, engines, Cloud Run services, VPC networks, attachments, forwarding rules, DNS zones, access policies or bindings, deny policies. Paid resources lived about 06:15Z-08:25Z. Still present after run 8: the three Model Armor floor settings (non-enforcing), the kept roles and T39b service account, KMS key rings and keys, and the run-6 Cloud Build log bucket.

Run 9 (2026-10-30, area B only): the same Terraform and toggles as run 8, plus `v2_gateway_t31r_register_blocked` (default off; one Agent Registry entry for `https://europe-west1-aiplatform.googleapis.com`, applied for T31R `post` and removed the same day). Agents G and B redeployed (new engine IDs). All area-B resources destroyed the same day; reset verified.

Reset state after run 7 (checked 2026-10-29 21:35Z): `infra/` and `infra/agents/` plans "No changes"; perimeter dry-run spec with 3 projects, no enforced status, no rules; no reasoning engines, agent gateways, Cloud Run services, Artifact Registry repositories, VPC networks, IAP V2 access policies or bindings, or deny policies on the runtime project or the folder. Still present: the three Model Armor floor settings (non-enforcing), the kept roles and service account, KMS key rings and keys (versions scheduled for destruction on 2026-11-27), and a Cloud Build regional log bucket created in run 6 (build logs only; human cleanup pending).

## Folder org policies under test

Effective values read with `gcloud org-policies describe --effective` (snapshot files `10-effective-*`, taken at base state, so the three toggle policies show their pre-toggle values). Terraform sets six policies on `fldr-lz-validation` and one on `fldr-ai-prod`; the supplement lists them by scope and shows none on any project.

| Test | Constraint | Folder | Effective value |
|---|---|---|---|
| T01 | iam.managed.disableServiceAccountKeyCreation | fldr-lz-validation | enforce |
| T02 | run.managed.requireInvokerIam | fldr-lz-validation | enforce |
| T03 | run.allowedIngress | fldr-lz-validation | allow `internal` |
| T04 | vertexai.allowedModels | fldr-ai-prod | allow `is:publishers/google/models/gemini-3.5-flash:predict` |
| T08 | gcp.resourceLocations | fldr-lz-validation | allow `in:eu-locations` (expanded by the API to a list of EU locations) |
| T09 | storage.publicAccessPrevention | fldr-lz-validation | enforce |
| T17 | run.allowedBinaryAuthorizationPolicies | fldr-lz-validation | allow `default` |

T04 test inputs: denied model `gemini-4-argon`, location `global`.

## Toggle policies (T05, T06, T07)

Off at base, on only in Stage 2 of each run, removed again in Stage 4. Values while on:

| Test | Constraint | Value when on | Value at base |
|---|---|---|---|
| T05 | vertexai.configurableComputerUseToolSafetyPolicies | deny all | `allowAll` |
| T06 | discoveryengine.managed.disableCustomMcpServerConnector | enforce | already `enforce=true` (Google default) |
| T07 | gcp.restrictNonCmekServices | deny `storage.googleapis.com` | `allowAll` |

T05 is not in the official constraint reference but the API accepted it. T06 was already enforced before our policy, so the test cannot show the effect of our policy (see errata E5 in [evidence/runs/errata.md](evidence/runs/errata.md)). T10 depends on T07. In run 3 (T14R only) all three toggles stayed off.

## Org-level policy

The only policy set at organization level in this environment is `iam.allowedPolicyMemberDomains` (list policy, present before this work; not managed by this repository). All policies under test are at folder scope.

## VPC Service Controls

- Two access policies under the organization: `lzv-org-access-policy-empty` (org level, no perimeters, no access levels; scoped policies need an org-level policy to operate) and `lzv-folder-scoped-policy` (scoped to `fldr-lz-validation`), which holds the perimeter.
- Perimeter `lzv_ai`: projects runtime2, mcp, data. Restricted services: `storage.googleapis.com`, `aiplatform.googleapis.com`. `prj-lzv-outside` is outside.
- Base state: dry-run spec only, no enforced status, no ingress rule.
- Enforced (status set) only in Stage 3a (no ingress rule) and Stage 3b (one operator ingress rule for storage and aiplatform, added with gcloud on the status and the dry-run spec). The perimeter was reset to dry-run in Stage 4 of each run. In run 3 the runtime project was first removed from the dry-run spec, then re-added at enforcement.
- While the perimeter is enforced, Terraform for `infra/` cannot plan, so gcloud was used for the ingress rule and the reset.

## Locked log bucket (T15)

`lzv-locked-logs` in `prj-lzv-data`, location `europe-west1`, retention 1 day, `locked: true` (snapshot `30-log-bucket.txt`). The lock is irreversible and was applied once, in a separate apply after the bucket was verified. It was not changed between runs.

## Agent runtime

- Fabric module `geap-agent-runtime` (`infra/agents/`), pinned to the Fabric commit below.
- An ADK agent with one tool that fetches a fixed URL (`https://example.com`); the caller cannot choose the target.
- Identity type left at the module default, `AGENT_IDENTITY` (a `principal://agents.global...` identity, no service account). No extra role grants in our Terraform.
- Agent A is deployed before the perimeter is enforced; agent B is deployed inside it (T14). Agents are paid resources and were destroyed in Stage 4 each time.

## Region

Resources, agents and the log bucket are in `europe-west1`. Model calls (T04 and the agents' own model calls) use location `global`, because the model was not served in europe-west1; calls to `global` are not pinned to an EU region. The T08 policy allows EU locations only.

## Tool versions and Fabric commit

| Tool | Version |
|---|---|
| Google Cloud SDK (gcloud) | 583.0.0 (core 2026.08.31); v1.1 run-4 used 583.0.0 (T20, T21, T24, T25) and 590.0.1 (T18, T19, T22, T23); run-5 to run-9 used 590.0.1 |
| Terraform | v1.17.0 (recorded in every `result.json`, runs 1-6; `notes/tool-versions.txt` lists v1.16.6 from Phase 0, before an upgrade) |
| Google provider | 8.8.0 |
| Python | 3.14.4 |
| jq | 1.8.2 |
| ShellCheck | 0.11.0 |

Cloud Foundation Fabric: `be0d4b10e4f8c6969d2f7a4faee086504b334fd0` (2026-10-22, "Add Vertex AI and Gemini Enterprise controls to FAST hardened dataset (#4288)"), module release v59.2.0, checked out in `vendor/fabric` (git-ignored).

## Stage sequence (per run)

Defined in [tests/RUN-ORDER.md](tests/RUN-ORDER.md). A wait of at least 15 minutes followed each org-policy or perimeter change.

1. Stage 1, base: T01, T02, T03, T17, T04, T08, T09, T06 `before`, T13 setup and dry-run, T15; agent A deployed; T11, T12, T14 `a`.
2. Stage 2, toggles on: T05, T06 `after`, T07, T10.
3. Stage 3a, perimeter enforced, no ingress: T13 `outside-read`.
4. Stage 3b, operator ingress rule: T13 `copy`; agent B deployed; T14 `b`.
5. Stage 4, back to base: agents destroyed, ingress removed, perimeter reset, toggles off, drift check.

Run 1: 2026-10-23 to 2026-10-24 (two days, with the runtime project replacement). Run 2: 2026-10-25, one sitting. Run 3: 2026-10-25, T14R only (separate sequence at the end of RUN-ORDER.md).

## Teardown (Phase 8, 2026-10-25)

Full teardown with `terraform destroy` (human decision: destroy everything). The first destroy stopped at the locked log bucket: `Error 400: Locked buckets currently cannot be deleted`, even with retention elapsed and no data. The bucket was removed from Terraform state only and its project deleted instead; deleting the project was allowed. Result, checked read-only on 2026-10-25: all test projects `DELETE_REQUESTED` (recoverable for 30 days, then removed by Google), both test folders and both access policies deleted, only the pre-existing `iam.allowedPolicyMemberDomains` left at organization level, billing account linked to the seed project only. Terraform state for `infra/` and `infra/agents/` is empty.

The v1.1 and v2 environment has not been torn down yet (2026-10-29). Runs 5, 6 and 7 and their resets are done. The Secure Web Proxy job subnet `lzv-swp-job` was held by a Cloud Run serverless IP address after T16 in runs 4, 5 and 7, and was deleted once the address was released (run 7: the same evening). The organization-level `roles/iam.denyAdmin` and `roles/modelarmor.floorSettingsAdmin` grants are kept (human decision 2026-10-28) until the human removes them. KMS key rings go with their projects.

## Cost

USD 0.01 for the test projects, 2026-10-23 to 2026-10-25, as shown in Cloud Billing reports on 2026-10-25 (read by the human; no billing export). Charges can appear up to a day late, so the final figure may be slightly higher. The v1.1 cost (run-4 and run-5, including the agents and the Secure Web Proxy gateway: about 11 gateway-minutes in run 4 and 26 in run 5) has not been recorded yet; the run-6 and run-7 costs have not been recorded either. A budget alert (`test-budget`, USD 50 per month, thresholds 50/90/100%) was set on the billing account.
