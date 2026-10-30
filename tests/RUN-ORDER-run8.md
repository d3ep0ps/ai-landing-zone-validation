# Run-8 order: Agent Gateway tests only (T30, T31, T32), gateway with VPC egress (DRAFT)

Status: draft, 2026-10-30. Nothing applied. Built from [RUN-ORDER-run7.md](RUN-ORDER-run7.md) day 3 and the run-7 day-3 log ([run-7.md](../evidence/runs/run-7.md)).

Purpose: a third attempt at area B. Run 6 stopped at a 401 (fixed in run 7 by the token-binding opt-out); run 7 stopped because the gateway could not reach the internal-ingress Cloud Run fixtures (Cloud Run front end 404; results.md Findings 25). Run 8 adds VPC egress for the gateway (`infra/v2-gateway-vpc.tf`, [notes/doc-verification-v2-B-netattach.md](../notes/doc-verification-v2-B-netattach.md)). Only T30, T31 and T32 run; every other test keeps its run-7 result. Expected results are unchanged (scripts' `header` text as committed). Report area B as "with agent token binding turned off, IAP policy V2, gateway VPC egress through a network attachment".

Run ID: `run-8` for each test; retries `run-8-rN`. Rules as in run 7:
- The human applies every plan and runs every gcloud change; Opus prepares saved plans (`-out=plan-run8-stageX.tfplan`) and runs the tests.
- Paid resources (gateway, agents, PSC endpoint) are created and destroyed the same day. Start early enough: run-7 day 3 took about 2 hours without agent B; with agent B (30 minutes after G) plan about 3 hours.
- Logins: fresh `gcloud auth login` and `gcloud auth application-default login` before each batch of applies; refresh during the 10-minute deny wait (run 7: logins expire after about an hour).
- Waits: 10 minutes after the deny policy (also covers the IAP V2 policy), about 4 minutes after Agent Registry changes before agent G.
- Gateway applies with `-parallelism=1`.
- Saved plans only.

## Before run 8

| # | Item | Status |
|---|---|---|
| R1 | Script matcher fixes (expected text unchanged; run-7 evidence-review findings). T30 and T31: replace the free-text `"DENIED" AND gateway-name` search with the gateway request log and the policy result field: `logName="projects/RUNTIME/logs/networkservices.googleapis.com%2Fgateway_requests" AND jsonPayload.authzPolicyInfo.policies.result="DENIED"` (field names seen in the run-7 logs), so the query's own audit entry and ALLOWED entries matching the rule name `default_denied` are no longer counted. T32: replace the `MATCH_FOUND` free-text search (it also matched `NO_MATCH_FOUND`) with `logName=".../logs/modelarmor.googleapis.com%2Fsanitize_operations" AND jsonPayload.sanitizationResult.filterMatchState="MATCH_FOUND"`. T30: also record the Cloud Run request-log count for `lzv-mcp-reg` (control reached the container: yes/no). Commit before the run | done 2026-10-30 (filters dry-tested on the run-7 logs: T30 1, T31 1, T32 MATCH_FOUND 0 / NO_MATCH_FOUND 5; registered origin 0) |
| R2 | `infra/v2-gateway-vpc.tf` reviewed by the human (VPC `lzv-gw-vpc`, subnet 10.77.5.0/28, attachment, PSC endpoint 10.77.6.10 `all-apis`, private zone `run.app.`) | to do |
| R3 | `dns.googleapis.com` on the seed project, in Terraform | done 2026-10-30 |
| R4 | Run-6 Cloud Build logs bucket (`<runtime number>-europe-west1-cloudbuild-logs`): delete or keep (it is reused by builds) | human |

## Day (single day)

| Stage | Apply before (human), then wait | Tests |
|---|---|---|
| 8-0 | Precheck (read-only): config, account, logins; APIs on seed and runtime (networkservices, networksecurity, agentregistry, iap, modelarmor, iam, dns); P8 `iam.managed.disableAccessPolicyBinding` enforce false on the runtime project; base state (0 engines, 0 Cloud Run services, 0 gateways, no VPC `lzv-gw-vpc`) | — |
| 8-0a | infra, untargeted: `enable_v2_gateway=true`, `enable_v2_model_armor=true`, `enable_v2_gateway_vpc=true` (expected about 52 add: run-7's 44 plus 8 VPC/DNS). **`-parallelism=1`**. Checks: access policy and binding `lzv-gw-egress`; `gcloud network-services agent-gateways describe lzv-gw --location=europe-west1` shows `networkConfig` (attachment, DNS peering `run.app.`); `gcloud compute network-attachments describe lzv-gw-attach --region=europe-west1` shows an ACCEPTED connection endpoint (may appear only after the first traffic: record what is seen). If the gateway create is refused because of `network_config`: record the error, stop the stage, switch to the connectivity-template resource (one fix, see stop rule) | — |
| 8-0b | `tests/fixtures/gateway/setup.sh build` and `setup.sh deploy` (MCP fixtures registered and unregistered, internal ingress, IAM invoker) | — |
| 8-0c | Build agent G (`agent_g/build.sh`, pinned packages). infra/agents: `deploy_agent_g=true`, at least 4 minutes after 8-0a. Check env `GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=False` and `agentGatewayConfig` -> lzv-gw | — |
| 8-0d | infra, targeted: project deny policy (T18 form), exception [G, run-8 engine]. Wait 10; refresh logins during the wait | — |
| 8-1 | none | T30, T32, T31 part 1 |
| 8-1b | Only if T30's registered-tool control answered: infra/agents `deploy_agent_b=true`, at least 30 minutes after G (not an exception in the deny policy) | T31 part 2 (re-run T31 as `run-8-r2` with both parts) |
| 8-2a | Reset, part 1: `teardown.sh run`; infra/agents destroy G (and B); infra with `enable_v2_gateway=false`, `enable_v2_model_armor=false`, `enable_v2_gateway_vpc=false`, `enable_dc1_deny=false`, **`-parallelism=1`**. Human deletes `gs://<runtime>_europe-west1_cloudbuild` | — |
| 8-2b | Reset, part 2 (only if 8-2a left the subnet or attachment, "in use"): wait 5 to 30 minutes (doc), re-plan, human applies. Checks: both stacks "No changes"; 0 gateways, engines, Cloud Run services; no `lzv-gw-vpc`, no PSC endpoint `lzvgwapis`, no zone `lzv-gw-runapp`; no access policy or binding `lzv-gw-egress`; no deny policies | — |

What to look for in 8-1 (beyond the verdicts):
- T30 control: the gateway request log shows the registered call with both policies ALLOWED and upstream status 200, and the Cloud Run request log for `lzv-mcp-reg` shows the call. This is the evidence that the VPC path works.
- If the control still gets 404 with no container request: record whether the gateway resolved `run.app` to 10.77.6.10 (if a DNS or gateway log shows it), the attachment state, and the gateway `networkConfig`. Do not change Cloud Run ingress (run 7: refused by `run.allowedIngress`, and it is a tested control).
- T32: Model Armor finding only counts with `filterMatchState="MATCH_FOUND"` in `sanitize_operations` (R1).

## Stop rule (area B, run 8)

- If the gateway create is refused because of `network_config`, one fix is allowed: switch to `google_network_services_agent_connectivity_template` (`vpc_egress = PRIVATE_RANGES_ONLY`, same attachment and DNS peering), re-plan, human applies. Then the rule below.
- If T30's registered-tool control fails (any status other than an answer from the fixture): record T30 to T32 INCONCLUSIVE with the gateway and Cloud Run logs, skip 8-1b, go to 8-2a. No retries that day.
- If IAP V2 refuses the registered tool (403 with `lzv-gw-iap-policy=DENIED`): fixture fault, record it, one fix (for example the condition), then the rule above.

## After run 8

- Redact the evidence (`tools/redact.py`, then the redaction-checker), commit, run the evidence-reviewer on the report diff, update the reports (area B results with the run-8 setup; X12, F21, F22 in the claims register).
- Record the costs of the gateway day (PSC endpoint, attachment, zone) from billing when available.
