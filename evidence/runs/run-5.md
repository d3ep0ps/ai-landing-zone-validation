# Run 5 (v1.1 repeat)

Order: [tests/RUN-ORDER-v11-run5.md](../../tests/RUN-ORDER-v11-run5.md) (human decision 2026-10-26: two agent deploys). Expected texts unchanged since the first v1.1 script commit (2a40b00), checked 2026-10-26.

Deviations from run-4 (planned):
1. T18 runs with the perimeter enforced, on the same two agents as T23.
2. Agent A for T19 is deployed while the runtime project is in neither the dry-run spec nor the status; it also serves T23 `pre`.
3. Script fixes since run-4: T22 VPC-SC signature (8430c2c), T25 build-object cleanup (cb0197b), SWP outputs (b138546).

## Day 1 (2026-10-26)

### Stage 0 (reset from the run-4 end state)

- 0a plan (infra/agents): destroy agents A and B (2 destroy). Waiting for human apply.
- 0a applied by human: agents A and B destroyed.
- 0b plan (targeted module.vpc_sc, data quota project): perimeter 1 change: status removed (3 projects -> none), dry-run spec keeps 3 projects, ingress rules (operator, agents) removed from spec and status. Waiting for human apply.
- 0b applied by human (~20:47Z): perimeter dry-run, ingress rules removed. Full untargeted plan (data quota project) then works: drift = only the SWP leftovers (job subnet + VPC, held by a Cloud Run serverless address; 4 API entries leave state only). Cleanup deferred to a later targeted plan.

### Stage 1 (T07 policy on)

- Plan (targeted at the `gcp.restrictNonCmekServices` folder policy, so the held SWP subnet does not fail the apply): 1 add, denied `storage.googleapis.com`. Waiting for human apply; then 15 min.
- Stage 1 applied by human 20:50Z (1 add). Wait 15 min, then T20, T21.

| Test | Verdict | Note |
|---|---|---|
| T20 (run-5) | PASS | No-CMEK bucket refused, CMEK bucket created; attribution by elimination (as run-4). |
| T21 (run-5) | PASS | First attempt: CMEK staging bucket build exit 0; plain build refused by `gcp.resourceLocations` (run-4 needed three attempts; the bucket grants from run-4 are in place). |

### Stage 2 (T07 policy off)
- Plan (targeted): 1 destroy (the `gcp.restrictNonCmekServices` folder policy). Waiting for human apply; then 15 min; then T24, T25.
- Stage 2 applied by human 21:40Z (1 destroy). Wait 15 min, then T24, T25.

| Test | Verdict | Note |
|---|---|---|
| T24 (run-5) | PASS | Entry in the locked bucket after 2 polls; retention change 1 -> 2 days refused; retentionDays stayed 1. |
| T25 (run-5) | PASS | Unattested digest refused ("is not authorized by policy"); same digest deployed after attestation. Cleanup: service deleted (the "failed" step is the describe check after the delete, which returns not found as expected); image deleted; 3 build objects deleted, "no new objects". The AR repository delete is a human step. |

Day 1 ends here (stages 0-2 done, 2026-10-26 ~22:00Z). Stages 3-9 (agents, SWP) are day 2.

## Day 2: stage 3 (2026-10-27)

- Before: config lz-validation, account and organization match PROGRESS.md; both logins valid; agents state empty (only the base data source).
- 04:42:50Z: runtime project removed from the lzv_ai dry-run spec with `gcloud access-context-manager perimeters dry-run update --remove-resources` (as run-3 step 0 and run-4 stage 8). Describe before: spec 3 projects, status 0, no ingress. After: spec 2 projects, runtime in neither spec nor status. Wait 15 min before T19 `before`.
- 04:58Z: T19 `before` (run-5): stage PASS, IAM snapshot written to evidence/T19/run-5/iam-before (all reads rc=0). Stage 4 plan: infra/agents plan-run5-stage4.tfplan, 1 add (agent A reasoning engine).
- Stage 4 applied by the human: agent A created (2m35s), 1 added.
- T19 `after` (run-5): PASS (Configured), per the pre-registered expected result (only allow-listed bindings may be added). added=0, extra none, removed none. **Observation (differs from run-4):** `roles/aiplatform.agentDefaultAccess` on the runtime project principalSet was already present in the `before` snapshot. It stayed after the run-4 agents were destroyed (run-4 stage 0a / stage 8), so this run did not see the binding appear at deploy. Run-4's `before` (fresh project) did not have it. C13's "added at deploy" is therefore not repeated by run-5; what run-5 shows is that the deploy added nothing else, and that the platform does not remove the binding when the agents are deleted.
- T23 `pre` (run-5): stage PASS. Runtime in neither spec nor status; agent A tool call to https://example.com returned 200.
- Stage 5 plan: targeted at module.vpc_sc (the full plan also destroyed the SWP leftovers, which stage 8 reuses), infra/plan-run5-stage5.tfplan: 1 change, only the runtime project added back to the dry-run spec.
- 2026-10-27T05:13:12Z: stage 5 applied by the human (1 changed). Describe: spec 3 projects incl. runtime, status 0. Wait 15 min before T22 `dryrun`.
- T22 `dryrun` (run-5): stage PASS. Dry-run violations in the last 30 min: old quota project 3, tooling quota project 0.
- Stage 6a plan: infra/plan-run5-stage6a.tfplan, targeted at module.vpc_sc, 1 change: status gets the 3 projects and the 2 restricted services (enforced); spec and status get ingress rules "operator" (operator user, aiplatform + storage) and "agents" (agent A principal, aiplatform on the runtime project).
- 2026-10-27T05:33:26Z: stage 6a applied by the human (1 changed). Describe: status 3 projects, 2 restricted services, 2 ingress rules. Wait 15 min before the agent B plan/deploy.
- 05:48Z: stage 6b plan infra/agents/plan-run5-stage6b.tfplan: 1 add (agent B), made after 15 min of enforcement.
- 07:55Z: stage 6b applied by the human: agent B created (2m36s) inside the enforced perimeter.
- Stage 6c plan: infra/plan-run5-stage6c.tfplan, targeted at module.vpc_sc with -var quota_project=<data>: 1 change, agent B principal added to the "agents" ingress rule in spec and status.
- 2026-10-27T07:57:42Z: stage 6c applied by the human (1 changed). Describe: "agents" ingress has 2 identities. Wait 15 min before T22 `enforced` and T23 `post`.
- T22 `enforced` (run-5, script 11dc4dd): **INCONCLUSIVE (recorded)**. Plan exit 1, read exit 0, enforced violations naming the tooling quota project 0, "plan failed without a VPC-SC signature". Opus read the plan error: one error, `module.prj_outside.data.google_storage_project_service_account.gcs_sa[0]`, 403 "Request is prohibited by organization's policy. vpcServiceControlsUniqueIdentifier: ..." (the same lookup as run-4-r2, F9). The signature was in the text; the check missed it because `PLAN_OUT` pointed to the shared `.last-output`, which the following bucket read overwrote. The same script fault may have contributed to run-4-r2. Fixed in 023ce5a (copy the plan output first); expected text unchanged.
- T22 `enforced` (run-5-r2, script 023ce5a): **FAIL**. Same single plan error (outside-project lookup refused by VPC-SC), read exit 0, violations naming the tooling quota project 0. The dry-run stage record was copied from run-5 (`stages/dryrun.json`), because the dry-run stage cannot be repeated with the perimeter enforced. The FAIL is against the pre-registered "Enforced: both succeed"; it is the F9 behaviour, now recorded by the script instead of INCONCLUSIVE.
- T23 `post` (run-5): **PASS** (Enforced). A (deployed before enforcement) tool status 200; B (deployed after) `URLError: [Errno 101] Network is unreachable`. No CONSUMER_SUSPENDED.
- T18 `pre` (run-5): stage PASS (deny off; both agents got model text, no permission denied). Printed approved principal = agent A output identity.
- Stage 7 plan: infra/plan-run5-stage7.tfplan, targeted at google_iam_deny_policy.dc1_agents_predict with -var quota_project=<data>: 1 add; denies aiplatform endpoints.predict to the runtime project agent principalSet, exception = new agent A.
- Stage 7 applied by the human: deny policy lzv-dc1-deny-agent-predict created, createTime 2026-10-27T09:17:50Z. T18 `post` after 09:28Z.
- Stage 8 on plan: infra/plan-run5-stage8-on.tfplan, targeted (google_project_service.swp, module.swp_vpc, module.swp_firewall, module.swp; -var quota_project=<data>): 10 add (gateway, policy, rule, 3 firewall rules, 3 routes, proxy-only subnet); VPC and job subnet reused from run-4.
- T18 `post` (run-5): **PASS** (Enforced), under the enforced perimeter (deviation 1). Agent B refused (403 PERMISSION_DENIED on aiplatform.endpoints.predict); approved agent A answered; policy age 647 s. No CONSUMER_SUSPENDED.
- 2026-10-27T09:36:15Z: stage 8 on applied by the human (10 added; gateway created ~2026-10-27T09:35:55.960722556Z).
- T16 (run-5): **PASS**. Allowed host via proxy 200; non-allowed host 403 on CONNECT, gateway_requests DENIED entry present; bypass timed out after 10 s (not DNS). Jobs: lzv-t16a-run5-k6skdn, lzv-t16b-run5-b76f2a, lzv-t16c-run5-6w8ud6 (human deletes). No CONSUMER_SUSPENDED.
- Stage 8 off: human deleted the 3 jobs in their own terminal (list shows 0); first apply attempt failed before running (`cd infra` from infra/); second apply destroyed 10 of 16 (gateway destroyed after 3m35s, about 26 gateway-minutes from 09:35:55Z; gateway list 0). Job subnet held by a Cloud Run serverless address again (as run-4); subnet, VPC and 4 API state entries remain (free); re-plan later.

## Stage 9 (reset)
- 9a: human destroyed agents A and B (2 destroyed). (One earlier attempt arrived as a chat message, not a shell command; nothing ran.)
- 9b plan: infra/plan-run5-stage9b.tfplan, targeted (module.vpc_sc, google_iam_deny_policy.dc1_agents_predict; -var quota_project=<data>): deny policy destroyed; perimeter status removed (back to dry-run), both ingress rules removed from spec and status; spec keeps its 3 projects.
- 9b applied by the human (1 changed, 1 destroyed). Describe: spec 3, status 0, no ingress; deny policies on runtime: none.
- 9c plan: infra/plan-run5-stage9c.tfplan (full, untargeted; perimeter in dry-run): 16 destroy: DC3 bucket (force_destroy) + its IAM + KMS key/ring (ring and key cannot be deleted; Terraform drops them from state), DC4 sink + writer IAM, SWP leftovers (subnet still held by the serverless address, expected to fail). tooling_quota_project=null, enable_t25_binauthz stays true until 9d.
- 9c applied by the human: 13 of 16 destroyed (DC3 bucket, KMS key/ring from state, IAM; DC4 sink and IAM; dc3 kms service). Job subnet failed again (held by a serverless address); subnet, VPC and the 4 SWP API state entries remain.
- 9d plan: infra/plan-run5-stage9d.tfplan (full): 14 destroy: T25 Binary Authorization policy, attestor, note, KMS key/ring (state only), signer IAM, 2 T25 API entries; plus the same SWP leftovers.
- 9d applied by the human: T25 Binary Authorization policy, attestor, note, signer IAM, KMS key/ring (state only; they cannot be deleted) and 2 API entries destroyed; the job subnet failed again.
- Checks after 9d: mcp Binary Authorization policy `evaluationMode: ALWAYS_ALLOW`; agents state has no engines; untargeted infra plan: only the 6 SWP leftovers (subnet `lzv-swp-job`, VPC, 4 API state entries; all free). Re-plan once Cloud Run releases the serverless address. No paid resources remain from run-5 (agents and gateway destroyed the same day).

## Run-5 results

| Test | Verdict | Run-4 | Note |
|---|---|---|---|
| T16 | PASS | PASS | Allow 200, deny 403 + DENIED log, bypass timeout. |
| T18 | PASS | PASS | Under the enforced perimeter this time (deviation 1). |
| T19 | PASS | PASS | added=0: the expected binding already existed from run-4, so "added at deploy" is not repeated (observation above). |
| T20 | PASS | PASS | |
| T21 | PASS | PASS (3rd attempt) | First attempt in run-5. |
| T22 | INCONCLUSIVE (run-5), FAIL (run-5-r2) | INCONCLUSIVE | run-5 missed the signature because of a script fault (`.last-output` overwritten); after the fix (023ce5a) the enforced plan is refused by VPC-SC on the outside-project lookup (F9), against the expected "both succeed". |
| T23 | PASS | PASS | |
| T24 | PASS | PASS | |
| T25 | PASS | PASS | |
