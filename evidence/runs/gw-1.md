# v3h gw 1 (2026-11-13), gateway-only (tests/run-v3h.sh gw)

Block 2 only: T53 v2 and T56 v2 (plan 3b, 5c3808a). Expected results: script headers (pre-registered).

## Log
- 14:01Z step preflight
- 14:01Z preflight OK (subset): PROJECT_8 empty, canary OK
- 14:01Z step build
- 14:01Z artifacts: agent_v3 sha256 3dcf5b7c2d4400b3..., agent_g sha256 b8d524168a5f1428...
- 14:01Z step b2-infra
- 14:02Z plan b2-infra: 76 changes (75 create 1 delete )
- 14:04Z apply b2-infra failed with a known propagation error; retry 1 of 2 in 180 s (Error: Error waiting to create AgentGateway: Error waiting for Creating AgentGateway: Error code 3, message: Config validation failed)
- 14:07Z plan b2-infra-retry: 3 changes (3 create )
- 14:13Z apply b2-infra-retry failed with a known propagation error; retry 2 of 2 in 180 s (Error: Error waiting to create AuthzPolicy: Error waiting for Creating AuthzPolicy: Error code 10, message: There is another ongoing operation for the same Agen)
- 14:17Z plan b2-infra-retry-retry: 1 changes (1 create )
- 14:19Z apply b2-infra-retry-retry: Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
- 14:19Z step b2-fixtures
- 14:20Z MCP fixture image sha256:1c5952108c6464052071d3a70cd478a62ed41617f9ed2ed8d6c185bce0ae3064; lzv-mcp-reg and lzv-mcp-unreg Ready
- 14:20Z replay image sha256:94be57416d08367bcae99058afe83a28bcf0ef65d43ee55e465cd6065133e46b; gateway MCP fixtures rebuilt and deployed
- 14:21Z plan b2-replay: 4 changes (4 create )
- 14:22Z apply b2-replay: Apply complete! Resources: 4 added, 0 changed, 0 destroyed.
- 14:22Z step s2-agents
- 14:22Z plan s2-agents: 6 changes (6 create )
- 14:35Z STOP: apply s2-agents failed: Error: Error waiting to create ReasoningEngine: Error waiting for Creating ReasoningEngine: error while retrieving operation: googleapi: Error 401: Request had invalid authentication credentials. Expe
- 14:35Z run stopped (rc=1) with paid resources up: teardown
- 14:35Z STOP: safety: organization of PROJECT_8 is '', PROGRESS.md says 'ORG_ID'
- 14:35Z teardown after stop FAILED: human check needed (agents, gateway, SWP)
- 14:41Z resume after the user's re-login (login expired at ~14:35Z, about 3 h after the 11:24Z login; documented rule: resume with the same command, finished steps skipped; infra still up because the stop teardown failed on the safety check)
- 14:41Z step s2-agents
- 14:41Z plan s2-agents: 1 changes (1 create )
- 14:44Z apply s2-agents: Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
- 14:44Z ready: v3-a after 2 s
- 14:44Z ready: v3-o after 2 s
- 14:44Z ready: v3-x after 2 s
- 14:44Z ready: g after 3 s
- 14:44Z ready: g-optout after 2 s
- 14:44Z step t53
- 14:44Z STOP: T53  aborted: ABORT: bad RUN_ID 'gw-1'
- 14:44Z tooling fixes (lib accepted only run-N ids; resume did not mark paid resources up, so the 14:44Z stop skipped teardown); resume again
- 14:44Z step t53
- 14:46Z T53  (gw-1): INCONCLUSIVE RESULT T53: INCONCLUSIVE
- 14:46Z step t56-calls
- 14:51Z T56 calls (gw-1): PASS 
- 14:51Z waiting 16 min: T56: >= 15 min after its last call (pre-registered late read)
- 15:07Z step t56-late
- 15:07Z T56 late (gw-1): FAIL RESULT T56: FAIL
- 15:07Z step teardown
- 15:07Z teardown: agents
- 15:07Z plan td-agents: 6 changes (6 delete )
- 15:09Z apply td-agents: Apply complete! Resources: 0 added, 0 changed, 6 destroyed.
- 15:09Z teardown: perimeter dry-run, ingress cleared, deny removed (targeted; full refresh fails while enforced)
- 15:10Z plan td-perim: 0 changes ()
- 15:10Z teardown: infra/ back to lz-5 + v3h-baseline
- 15:11Z STOP: plan td-infra has unexpected changes (not applied): delete google_artifact_registry_repository_iam_member.v3h_mcp_pull[0];
- 15:11Z gw run 1 finished
- 15:11Z step redact
- 15:11Z redaction: redacted 9/14 files; check: checked 14 files, 0 with findings (T43 gw-1 redacted at close)
- 15:12Z teardown allowlist fix (new v3h_mcp_pull binding was missing from ALLOW_TEARDOWN; the 15:11Z td-infra plan stopped with paid resources up); resume for teardown
- 15:12Z gw run 1 finished
- 15:12Z step teardown
- 15:12Z teardown: agents
- 15:12Z plan td-agents: 0 changes ()
- 15:12Z teardown: perimeter dry-run, ingress cleared, deny removed (targeted; full refresh fails while enforced)
- 15:13Z plan td-perim: 0 changes ()
- 15:13Z teardown: infra/ back to lz-5 + v3h-baseline
- 15:13Z plan td-infra: 88 changes (1 create 87 delete )
- 15:27Z orphan engine lzv-v3-x (created 14:34Z by the s2-agents apply that failed with 401; not in Terraform state) deleted by REST DELETE (force=true), matched by name and createTime
- 15:33Z apply td-infra failed with a known propagation error; retry 1 of 2 in 180 s (Error: Error when reading or editing NetworkAttachment: googleapi: Error 412: Network Attachment with connected endpoints cannot be deleted., conditionNotMet)
- 15:37Z plan td-infra-retry: 35 changes (35 delete )
- 15:57Z STOP: apply td-infra-retry failed: Error: Error when reading or editing NetworkAttachment: googleapi: Error 412: Network Attachment with connected endpoints cannot be deleted., conditionNotMet
- 15:57Z teardown: PSC-I attachment still has endpoints from deleted agents; background poll will finish it (free resources)
- 15:57Z gw run 1 finished
- 15:57Z step redact
- 15:57Z redaction: redacted 0/14 files; check: checked 14 files, 0 with findings (T43 gw-1 redacted at close)

## Analysis (2026-11-13, written after the run; no expected result changed)
- Paid resources after teardown (15:58Z): 0 agent gateways, 0 engines, 0 SWP gateways, 0 addresses, 0 forwarding rules. Known free PSC-I leftovers (412).
- Interruptions, all handled by resuming the same command: login expired at ~14:35Z (about 3 h after login; s2-agents apply 401; stop teardown failed its safety check); lib rejected the gw-1 run id (fixed, 5faaf36); resume did not mark paid resources up (fixed, 5faaf36); teardown allowlist lacked the new v3h_mcp_pull binding (fixed); orphan engine lzv-v3-x from the 401 apply deleted by REST.
- **MCP fixture:** the fix worked for build and deploy (image built in the quota project, both services Ready). Every allowed call then got 401 from Cloud Run ("The access token could not be verified"; Cloud Run request log 14:47-14:48Z), while the gateway logged both authz policies ALLOWED. Agent G's credential for the fixture (auth=id_token) is not accepted by Cloud Run. Fixture defect, not the control under test; cause not investigated further.
- **T53 v2 INCONCLUSIVE** (pre-registered: control not 200). All three direct attempts were refused by the gateway (example_ip connected to an address in the reserved Class E range 240/4; the address is redacted in the evidence as an IP placeholder).
- **T56 v2 FAIL** (pre-registered): 8 calls excluded (401, fixture). Of 5 unregistered_echo calls (403 from IAP, before the backend, so the fixture does not affect them), one has no gateway_requests record at the late read. Same pattern as run 7 (v1): 1 of 5 denied calls without a record in each run. Limitation as in run 7: gateway log sampling not configured by us; Google's default not checked.

## T53/T56 fixture 401: cause (investigated 2026-11-13 after the run; no expected result changed)
- **Cause (source and docs, not yet confirmed by a run):** agent G (`g`, token binding on, as v3h deploys it) gets its credential for the MCP fixture with `id_token.fetch_id_token(request, url)` and the default `bind_id_token=None`. In google-auth 2.62.1 (agent G's pinned version; source read 2026-11-13) that default makes `IDTokenCredentials` POST the agent certificate chain to the metadata identity endpoint (`compute_engine/credentials.py` `bind_token = _bind_id_token is not False`; `_metadata._build_token_request_options`), so the ID token is certificate-bound. Docs (iam/docs/auth-agent-own-identity-external, fetched 2026-11-13): "By default, supported Google Auth client libraries cryptographically bind OIDC ID tokens to the agent's unique X.509 certificate"; "Cloud Run automatically enforces certificate binding when the `cnf` claim is present in an ID token"; bound tokens must be sent to `*.mtls.run.app` over mTLS. The gateway ends the agent's TLS session and opens a new one, so Cloud Run cannot match the binding and answers 401 "The access token could not be verified".
- **Consistent with every earlier observation:** v2 runs 8 and 9 (T30 PASS, control 200, auth=id_token) ran agent G with the token-binding opt-out; v3h run-1-r2 (replay service 401, same message) ran the v3 agent with binding on, before the 13:28Z opt-out redeploy; gw 1 ran `g` with binding on.
- **Not affected:** the gateway refusals (403 before the backend) in T53 and T56; T56's missing record is on an IAP-denied call.
- **Fix options (decision pending, would be a new version with a pre-registration):** per-request `bind_id_token=False` in agent G's `call_mcp_tool` only (agent G's other tokens stay bound); or use `g_optout` for the control (changes the claim to "binding off"); turning the fixture's invoker check off is not available (folder policy run.managed.requireInvokerIam).
