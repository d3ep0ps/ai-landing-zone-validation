# Run-9 order: repeat of run 8 (T30, T31, T32) plus the T31R re-test (DRAFT)

Status: draft, 2026-10-30. Nothing applied. Built from [RUN-ORDER-run8.md](RUN-ORDER-run8.md) and the run-8 log ([run-8.md](../evidence/runs/run-8.md)).

Purpose:
1. Repeat run 8 unchanged, so the area-B results (C27 T30, C28 T32) rest on two runs instead of one (X13). Same Terraform, same toggles, same scripts, same expected results.
2. Run T31 again as is (its expected text cannot change after its runs).
3. Run T31R, a new pre-registered test (design below, R1). It fixes T31's weak point: T31 attributes the 403 to the gateway only through a `gateway_requests` DENIED entry, and that log does not record every request (run 8, F24). T31R attributes the 403 by changing one thing, the gateway registry, and nothing on the IAM side.

Report area B as in run 8: "with agent token binding turned off, IAP policy V2, gateway VPC egress through a network attachment".

Run ID: `run-9` for each test; retries `run-9-rN`. Rules as in run 8:
- The human applies every plan and runs every gcloud change; Opus prepares saved plans (`-out=plan-run9-stageX.tfplan`) and runs the tests.
- Paid resources (gateway, agents, PSC endpoint) are created and destroyed the same day. Plan about 3.5 hours (run 8 took about 3 hours; T31R adds one targeted apply and a 4-minute wait).
- Logins: fresh `gcloud auth login` and `gcloud auth application-default login` before each batch of applies; refresh during the 10-minute deny wait and again before 9-1c (logins expire after about an hour).
- Waits: 10 minutes after the deny policy (also covers the IAP V2 policy); about 4 minutes after any Agent Registry change before the next agent call; **30 minutes between agent deploys, measured from the G apply time written in the run log** (run 8 applied B about 9 minutes early, Deviation 22).
- Gateway applies with `-parallelism=1`. Saved plans only.

## Before run 9

| # | Item | Status |
|---|---|---|
| R1 | T31R design approved by the human (2026-10-30). `tests/T31R.sh` (`pre`/`post`) and toggle `v2_gateway_t31r_register_blocked` (infra/v2-gateway.tf, default off) written; checks: `bash -n` ok, `terraform validate` ok, plan with the toggle off: no changes; plan with gateway and toggle on lists `lzv-ep-t31r-blocked` with url `https://europe-west1-aiplatform.googleapis.com` | done 2026-10-30 |
| R2 | No change to T30, T31, T32 since the R5 fix commit except the R5 header fix itself (`git diff 75dc030 -- tests/T30.sh tests/T31.sh tests/T32.sh` empty); expected text identical to run 8 | check at 9-0 |
| R3 | Decide on the "default setup" stage (9-3, below): run it, or leave the default setup as not shown | human |
| R4 | Run-6 Cloud Build logs bucket: delete or keep (open since run 8) | human |
| R5 | Evidence-format defect found 2026-10-30: T30, T31 and T32 call `header` with one argument too many (`"B"` plus a separate control text). In runs 6 to 8 their `result.json` field `expected` holds the control text, and the pre-registered expected text is in the first line of `output.txt` as `stage=...` (and in `command.txt`). The expected text itself was written before each run (script commits). Decide: (a) fix the argument order before run 9 (expected text unchanged, like the R1 matcher fix of run 8; R2 then compares against the fixed commit), or (b) run unchanged and fix after. Either way record it as a finding for runs 6 to 8. T31R is not affected | fixed 2026-10-30 (human chose (a)): control text joined to the check text ("...; control: ..."), expected text byte-identical to run 8; dry runs show `expected` correct and no stage. Finding for runs 6 to 8 still to record in the reports |

## Day (single day)

| Stage | Apply before (human), then wait | Tests |
|---|---|---|
| 9-0 | Precheck (read-only), as 8-0: config, account, logins; APIs on seed and runtime; P8 `iam.managed.disableAccessPolicyBinding` enforce false on runtime; base state (0 engines, 0 Cloud Run services, 0 gateways, no `lzv-gw-vpc`); R2 | — |
| 9-0a | infra, untargeted: `enable_v2_gateway=true`, `enable_v2_model_armor=true`, `enable_v2_gateway_vpc=true` (run 8: 52 add). **`-parallelism=1`**. Checks as 8-0a (access policy and binding `lzv-gw-egress`; gateway `networkConfig`; attachment) | — |
| 9-0b | `tests/fixtures/gateway/setup.sh build` and `setup.sh deploy` | — |
| 9-0c | Build agent G (`agent_g/build.sh`, same pins as run 8). infra/agents: `deploy_agent_g=true`, at least 4 minutes after 9-0a. **Write the G apply time in the run log.** Check env `GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=False` and `agentGatewayConfig` -> lzv-gw | — |
| 9-0d | infra, targeted: project deny policy (T18 form), exception [G, run-9 engine]. Wait 10; refresh logins during the wait | — |
| 9-1 | none | T30, T32 (T31 waits for B) |
| 9-1b | Only if T30's registered-tool control answered, and **not before G apply time + 30 minutes**: infra/agents `deploy_agent_b=true` (not an exception in the deny policy). Wait about 4 minutes | T31 (both parts in one attempt); `RUN_ID=run-9 bash tests/T31R.sh pre` |
| 9-1c | Only if T31R `pre` recorded a 403: infra, targeted (`-target=google_agent_registry_service.v2_ep_t31r_blocked`): `v2_gateway_t31r_register_blocked=true` (registers `europe-west1-aiplatform.googleapis.com` in the Agent Registry; nothing else changes). Wait 4; refresh logins | `RUN_ID=run-9 bash tests/T31R.sh post` (retries the call every 2 minutes until the entry is 10 minutes old) |
| 9-1d | infra, targeted: T31R toggle off (back to the run-8 registry) | — |
| 9-2a | Reset, part 1, as 8-2a: `teardown.sh run`; infra/agents destroy G and B; infra with `enable_v2_gateway=false`, `enable_v2_model_armor=false`, `enable_v2_gateway_vpc=false`, `enable_dc1_deny=false` (and the T31R toggle false), **`-parallelism=1`**. Human deletes `gs://<runtime>_europe-west1_cloudbuild` | — |
| 9-2b | Reset, part 2 (only if the subnet or attachment was "in use"): wait 5 to 30 minutes, re-plan, human applies. Checks as 8-2b | — |

Order change from run 8: T31 runs once, after B exists, so both its parts are in one attempt (run 8 needed r2 for part 2). This is the run order, not a change to T31.

What to look for in 9-1 (beyond the verdicts):
- T30 and T32: the same outcome as run 8, or a difference to record. Run 9 is the second run of the same setup; a different result is a finding, not a retry reason.
- T31: whether `gateway_requests` has the DENIED entry this time (F24: the log is incomplete).
- T31R: the 403 body text in `pre`, and the status in `post`.

## Stop rule (area B, run 9)

- As run 8. If T30's registered-tool control fails: record T30 to T32 (and T31R) INCONCLUSIVE with the gateway and Cloud Run logs, skip 9-1b to 9-1d, go to 9-2a. No retries that day.
- T31 and T31R: one attempt each; one retry only if the attempt failed for a setup reason (login expired, agent not ready), written in the run log before the retry.
- If the 9-1c apply is refused: T31R `post` is not run (INCONCLUSIVE), go to 9-1d. If the apply succeeds and the call still gets 403 when the registry entry is 10 minutes old, the script records FAIL (verdict rule: the refusal was not the registry); go to 9-1d.

## T31R design (for R1, human approval)

Re-test of T31's first claim, like T14R for T14. T31 and its run-6 to run-8 results stay as they are.

Claim tested: the gateway itself refuses a model call to an endpoint that is not in its registry, while IAM allows the agent.

Why T31 could not show it: a 403 alone does not say who refused. T31 required a DENIED entry in `gateway_requests`; run 8 showed that log misses requests (F24), so two of three attempts were INCONCLUSIVE although the agent got the same 403.

Method (differential): one thing changes between two stages, the gateway registry. IAM does not change (same deny policy, G still an exception, same agent, same call). If the call is refused before and answered after, the refusal came from the registry check.

Stages (script `tests/T31R.sh pre|post`, run ID `run-9`):
- `pre` (registry as in run 8; B deployed). Guards: deny policy present and at least 10 minutes old, G an exception, B not an exception, `europe-west1-aiplatform.googleapis.com` not in the registry. Calls: (a) G, allowed endpoint (control); (b) G, blocked endpoint; (c) B, its own model call. Records the bodies, and as supporting evidence only the `gateway_requests` DENIED count and the IAP audit entries in the window.
- `post` (after 9-1c: the regional host registered). Guards: same deny policy, same createTime, same exceptions (unchanged since `pre`); the host is in the registry. Call: (d) G, the same blocked-endpoint call. Writes the result.

Pre-registered result (written in the script before it runs):
- Check: "Allowed endpoint answered in `pre`; IAM state identical in `pre` and `post`"
- Expected: "`pre`: G's call to the unregistered model endpoint is refused (403) although IAM allows G; `post`: after only the registry changes, the same call is answered (200); B is refused by the IAM deny policy (\"due to an IAM deny policy\")"

Verdict rules:
- PASS: (a) 200; (b) 403; (c) PERMISSION_DENIED with "IAM deny policy"; (d) 200; guards show no IAM change.
- FAIL: (b) answered 200 (gateway did not refuse); or (d) still 403 after 10 minutes while the host is listed in the registry (the refusal was not the registry: finding); or (c) answered (deny policy did not stop B).
- INCONCLUSIVE: control (a) not 200; any guard fails; B not deployed; `post` not run.
- Not asserted: the 403 body text and the log entries (recorded as observed).

Limitations to state with the result: one run; the setup is the run-8 setup (token binding off, IAP V2, VPC egress); `post` shows the registry decides this call, not which gateway component (registry check or IAP policy `destination.is_registered`) refused it. Both are gateway-side.

Terraform toggle (one variable, default false): `v2_gateway_t31r_register_blocked`. When true, one more `google_agent_registry_service` with url `https://europe-west1-aiplatform.googleapis.com`. The IAP V2 rule allows registered destinations (`destination.is_registered == true`), so no policy change is needed.

## 9-3 Default setup (optional, only if R3 says run it)

"Default setup" here means: agent G deployed the way the docs describe, without the token-binding opt-out (`agent_g_caa_token_binding_opt_out=false`). In run 6 this got 401 UNAUTHENTICATED from Vertex AI after the gateway allowed the call (F16). This stage asks one question: does the default setup work now? It would be a new pre-registered test (proposed ID T30D: control call through the gateway answered, yes or no), with its own approval. Cost: one more agent deploy, at least 30 minutes after B, so about 45 minutes more before reset. Recommended: a separate short run, not run 9, so run 9 stays an exact repeat.

## After run 9

- Redact the evidence (`tools/redact.py`, then the redaction-checker), commit, run the evidence-reviewer on the report diff, update the reports (C27, C28 with two runs; T31 and T31R; X13; F24).
- Record the R5 header defect as a finding for runs 6 to 8 (result.json `expected` held the control text; the pre-registered text is in output.txt line 1 and command.txt).
- Record the costs of the gateway day from billing when available.
