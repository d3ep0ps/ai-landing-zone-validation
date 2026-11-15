# v3h run 1 (2026-11-11)

Plan: plans/v3-harness-boundary-tests.md; order tests/RUN-ORDER-v3h.md. Run by Opus autonomously (human authorised apply/destroy 2026-11-11).

## Pre-registered decisions (before any test step)
- D1-D5: the five gap-fills at the end of tests/RUN-ORDER-v3h.md, approved by the human 2026-11-11.
- D6: no new projects (human 2026-11-11). Per-run project = existing never-agent project: run 1 PROJECT_9, run 2 -data, run 3 -outside. Checked 2026-11-11: none has an agentDefaultAccess binding. infra-v3h existing_project_id mode; APIs enabled with disable_on_destroy=false.
- D7: T40b runs in the run-1 project after T43 closes (needs an agent already deployed, not a fresh project).
- Baseline: infra/ lz-5 + profiles/v3h-baseline.tfvars (folder deny off, perimeter dry-run).

## Artifact
agent_v3 tarball sha256: 85e595f8ed1add4e4e8b38aa3c64b285de1803f40eb068c69bf754111a342815 (infra-v3h/build/source.tar.gz == infra/agents/build/source-v3.tar.gz)

## Log
- 09:33Z step 0 applied (10 add: operator IAM x3, APIs x7). T40 before PASS, T42 before PASS.
- 09:38Z step 3: agent 1 deployed in mcp (4m14s, reasoningEngines/...6352; plan 1 add). Fix before apply: infra-v3h agent_source_path default -> build/source.tar.gz (plan failed on the old path).
- 09:43Z T40 after -> T40 run-1 FAIL (script verdict kept). IAM diff added 3: agentDefaultAccess on the project principalSet (as predicted) + 2 Vertex service-agent bindings (reasoningEngineServiceAgent, aiplatform.serviceAgent) created at first Vertex use. Plan exit 0 before and after; audit SetIamPolicy with agentDefaultAccess at 09:34:37Z by USER_5@example.com (Google-managed), during the deploy.
  FINDING v3h-F1: the pre-registered "one new binding" was too narrow; first agent deploy also adds Vertex service-agent bindings out of band. Expected text NOT changed. Question for human before run 2: pre-create Vertex service agents in step 0 (setup change) and/or amend the run-2/3 expected text.
- 09:45Z T42 after PASS (T42 run-1 PASS); T41 before PASS. Block-2 infra planned (infra/ lz-5 + v3h-baseline + v3h-block2: 53 add, 0 change/destroy; plan-v3h-r1-b2.tfplan). Apply in infra/ blocked by the auto-mode classifier (protected-scope IaC); asked human. Agent 2 deploy timer to 10:08Z.
- 09:47-10:00Z block-2 infra (infra/ + profiles/v3h-block2.tfvars; human added an allow rule for saved-plan applies at ~09:49Z). Apply 1: 50/53 created, Agent Gateway create failed "Config validation failed" (fieldViolation: gateway service agent needs roles/compute.networkViewer on the DNS peering network's project). FINDING v3h-F2: runs 8/9 (2026-10-30) did not need this grant. Fix: google_project_iam_member.v2_gw_sa_network_viewer (v2-gateway-vpc.tf). Apply 2: grant created, gateway failed again on networkAttachments.get (in networkViewer; IAM propagation, grant 10 s old). Waiting 3 min, re-plan.
- 10:07Z dns.reader grant added (third missing permission, same F2); gateway create retried. 10:11Z step 7: agent 2 deployed in mcp (2m14s, ...2544; plan 1 add).
- 10:16Z T41 after: added=0; agent 2 (no roles) ACTION=model MODE=bypass status 200; Troubleshooter PERMISSION_DENIED (policytroubleshooter API not enabled on quota project seed) -> T41 run-1 INCONCLUSIVE (fixture). Fix for run 2: google_project_service.v3h_troubleshooter.
- 10:12-10:23Z block-2 infra complete: gateway (3 add after dns.reader), replay repo + Troubleshooter API (3 add), replay image built in seed (sha256:f9148eef...), gateway MCP fixture build+deploy (setup.sh), replay service (3 add; principalSet invoker accepted by org domain policy), T45c buckets (4 add: outside CMEK bucket, probe object, bucket IAM). Agent G tarball sha256 22f2726f25e3bf98... v3a planned (1 add), deploy at 10:41Z (30-min spacing).
- 10:44Z v3a deployed (2m35s, runtime ...0096). T46 run-1 NOT_TESTED (Documented, doc evidence). Agent G planned (2 add; binding default, gateway lzv-gw).
- 11:18Z agent G deployed (binding default).
- 11:23Z T47 s1 PASS (v3a direct, model 200). T47 s2 FAIL: agent G (binding default, gateway lzv-gw) tool call class=200, expected 401.
  Gateway log check (scratch/v3h-r1-T47-s2-gwlogs.json): 11:23:07.212Z POST https://aiplatform.googleapis.com/v1/.../publishers/google/models/...:generateContent status 200 authzPolicyInfo.result=ALLOWED, so the call did go through lzv-gw. The tool sends the bearer token with plain `requests` (no client certificate).
  FINDING v3h-F3: with token binding on by default (env fields read=3, opt-out not set; google-auth 2.62.1), a call through the Agent Gateway was accepted (200), not refused (401). This is the plan's falsifier for B8. Limitation: the gateway may present its own certificate upstream, so this run cannot say which hop binding is checked at. Expected text NOT changed.
- 11:25Z G opt-out=true planned (plan-v3h-r1-g-optout.tfplan: 1 in-place, adds GOOGLE_API_ENABLE_RUNTIME_BOUND_TOKEN=false + deprecated var); apply at >= 11:48Z (30-min spacing).
- 11:26Z T48 bound run-1 INCONCLUSIVE: agent query HTTP 503 "Authentication backend unavailable" (transient; operator control 200 5 s earlier). Retry as run-1-r2 (11:27Z): INCONCLUSIVE, own=401, replay service HTTP 401, control2=200.
  Two fixture defects (not binding results):
  (a) agent_v3 _replay() makes its "own call" with plain `requests` and no client certificate. Under default binding the runtime's own bound token is refused (401) when sent without the certificate, so control 1 cannot be 200 as written. The genai client (ACTION=model) presents the certificate and got 200 in T47 s1. Side observation: same workload, bound token, no certificate, direct to aiplatform.googleapis.com -> 401. Compare T47 s2: no certificate, through the gateway -> 200 (F3).
  (b) Cloud Run invoker auth rejects the agent's ID token: "The access token could not be verified" (scratch/v3h-r1-T48-replay-runlogs.json, 11:27:05Z). The agent identity ID token is not accepted by Cloud Run IAM invoker checks.
  Both need a fixture change + v3a redeploy; asked human.
- 11:30-11:40Z human chose "fix both, retry today" (D8). (a) agent_v3 _replay(): control 1 = AuthorizedSession + configure_mtls_channel() to aiplatform.mtls.googleapis.com (google-auth 2.62.1 source checked: AuthorizedSession does not mount the cert lazily); new observation own_nocert_status = same token, regular endpoint, no cert; replay POST no longer sends an ID token. Offline mock test of _replay passed. New tarball sha256 db27c21b0b79721db5e4ccfff48fbb308813ce3ca13f20c89cdc4d5a4c51109e (also written to infra-v3h/build; agents 1-2 not redeployed). (b) v3h_replay_auth=false -> replay service invoker_iam_disabled (applied 11:31Z, 1 in-place). T48 expected text unchanged; retry will be run-1-r3 after v3a redeploy (>= 12:18Z).
- 11:51Z G opt-out=true applied (2m55s). 11:55Z T47 s3 PASS (opt-out env set=1, through gateway 200 where=tool).
  Gateway log (scratch/v3h-r1-T47-s3-gwlogs.json): the tool's plain call shows only as CONNECT 200 at 11:55:28Z (no decoded POST record), unlike s2 where the same call was logged as POST aiplatform.googleapis.com 200 ALLOWED. Observation only; not part of the verdict.
- 12:24Z v3a redeployed with fixed fixture (2m34s). 12:25Z G opt-out=false planned (plan-v3h-r1-g-default.tfplan), apply >= 12:52Z.
- 12:28Z T48 bound run-1-r3 PASS: own call (mTLS, own cert) 200; operator control 200; same token replayed from the Cloud Run service (seed project, no client cert) -> 401 UNAUTHENTICATED "Request had invalid authentication credentials...". Limitation stands: no-cert vs wrong-cert not separated.
  Extra fields: own_call_mtls=true, own_token_same=true, own_nocert_status=401 (the agent itself, same token, regular endpoint, no cert -> 401). So binding refuses a no-cert use even from the agent's own runtime; consistent with the 401 seen from the replay workload.
- 12:29Z T44 pre PASS (moved earlier: state already matched step 19; perimeter dry-run, v3a only, artifact sha db27c21b...). A model 200, A denied-host 200.
- 12:54Z G opt-out=false applied (2m44s). 12:58Z T47 s4 FAIL (env set=0, through gateway 200 where=tool). T47 run-1 FAIL (s1 PASS, s2 FAIL, s3 PASS, s4 FAIL): binding default did not produce a 401 through the gateway in this setup (F3, reproduced after the opt-out round trip). 12:55Z v3a opt-out=true planned (plan-v3h-r1-v3a-optout.tfplan), apply >= 13:24Z.
- 13:28Z v3a opt-out=true applied (2m56s). 13:33Z T48 optout run-1-r3 PASS: own 200 (mTLS), own_nocert 200, control2 200, replayed 200. T48 run-1-r3 PASS (run-1, run-1-r2 INCONCLUSIVE kept).
- 13:34Z step 21: perimeter enforced (runtime, mcp, data in status; no agent ingress rule; profiles/v3h-block3.tfvars).
  D9 (my call, recorded before T44 noingress): v3a keeps agent_v3_token_binding_opt_out=true through T44 (restoring it would redeploy A after enforcement and break the T44 deploy-order design); B is deployed with the same value (one variable for both v3 agents), so A and B differ only in deploy order. T44 pre ran with A opt-out=false (dry-run baseline). The opt-out goes back to false in the T45 PSC-I redeploys.
- 14:02Z v3b deployed (2m46s, ...2048) after enforcement (13:34Z). 14:06Z T44 noingress FAIL (script verdict kept): A model and A tool: the whole agent query returned 403 VPC-SC (no result line, so the script logged status=none); B tool (non-allowed host) 200, B model 200.
  VPC-SC audit (scratch/v3h-r1-T44-noingress-vpcsc.json): both A denials = aiplatform SessionService.CreateSession, ingress violation NO_MATCHING_ACCESS_LEVEL, target runtime project, caller A's agent principal. No denial for B.
  FINDING v3h-F4: with the perimeter enforced and no agent ingress rule, the agent deployed BEFORE enforcement (A) is treated as an outside caller (its session creation is refused, so it cannot run at all), while the agent deployed AFTER enforcement (B) runs and still reaches a public host (*.run.app). Plan expected B without internet. Limitation: both agents had the token-binding opt-out (D9); the target host is a Google-fronted run.app URL, not an arbitrary internet host.
- 14:09Z step 24: agent ingress rule [A, B] applied (targeted plan -target=module.vpc_sc: full refresh fails because the operator cannot read the T45 probe object inside the enforced perimeter, 403 VPC-SC). T44 ingress at >= 14:24Z.
- 14:25Z T44 ingress: A and B both model 200 and non-allowed host 200. T44 run-1 FAIL (script verdict kept): no egress difference by deploy order; B reached a public run.app host with the perimeter enforced (F4).
- 14:26-14:29Z T45 setup: perimeter to dry-run (targeted) so Terraform can refresh; SWP + PSC-I (allowlist = allowed target host) + DC1 project deny (exception: v3a identity) applied (20 add; v3_net compute service entry dropped from state, disable_on_destroy=false, now managed by swp); perimeter re-enforced 14:29Z (ingress rule [A, B] kept). Agents: agent_v3_use_psci=true, opt-out=false (ends D9); v3a redeploy (targeted, in-place, identity unchanged) at >= 14:32Z, v3b at >= 15:03Z.
  D10 (recorded before T45 off): 'project out of the perimeter (spec and status)' is done as perimeter dry-run (vpc_sc_enforced=false): runtime leaves status; the spec (dry-run, log only) keeps it because infra/ has no per-project spec switch. T45.sh off guard checks status only.
- 14:42Z D11 (human): deploy spacing reduced to 15 min (runtime project PROJECT_8 allowlisted by Google). Replaces the 30-min rule from here on.
- 14:35Z v3a PSC-I redeploy (2m46s). 14:53Z v3b PSC-I redeploy (2m45s). T45 on at >= 15:08Z (15 min after last change).
- 15:08Z T45 on run-1 INCONCLUSIVE: platform cells all refused (a-bypass 403 deny "aiplatform.endpoints.predict", b-bypass-proxy SWP tunnel 403, c-bypass 403 VPC-SC "prohibited by organization's policy"); harness guarded cells refused by adk_callback; controls a 200, b-allowed 200; NOT PASS: ctl-c-src-bucket 403 "storage.objects.create" (fixture IAM gap: agents had only objectViewer on the source bucket) and b-bypass-direct (agent query hung 240 s, no bytes).
  D12 (human: fix both, retry): v3h_src_create (objectCreator on source bucket for the runtime agents principalSet; applied 15:16Z in a 2-min dry-run window, perimeter re-enforced 15:17Z); agent_v3 direct cell = dedicated no-proxy opener (urlopen's global opener caches proxy env) + 20 s hard deadline (DNS not covered by urlopen timeout). New tarball sha256 5fcdf8fae68c02dae47a3a5daa932d5b0efa9a63b02a4130f1cb7b485753fee8. T45 retry = run-1-r2 (on + off). run-1 kept.
- 15:20Z v3a redeploy (r2 tarball, 2m25s); 15:37Z v3b redeploy (2m44s). T45 on run-1-r2 at >= 15:52Z.
- 15:52Z T45 on run-1-r2 PASS (controls a/b/c 200; guarded a/b/c adk_callback; bypass a 403 deny, b proxy SWP 403, b direct no answer within 20 s (deadline), c 403 VPC-SC).
- 15:54-15:57Z T45 off setup: perimeter dry-run (D10), DC1 deny destroyed, v3a redeployed without PSC-I (2m25s). v3b at >= 16:12Z; T45 off at >= 16:27Z.
- 16:15Z v3b redeployed without PSC-I (3m6s). T45 off at >= 16:30Z.
- 16:30Z T45 off run-1-r2: all bypass cells allowed (a 200, b proxy 200, b direct 200, c to outside bucket 200); guarded cells refused by adk_callback; controls a/b 200; ctl-c-src-bucket 403 "storage.objects.delete": the destination object name is fixed (lzv-copy-lzv-v3-b) and already existed from the on stage, so the copy is an overwrite. T45 run-1-r2 INCONCLUSIVE (script verdict kept). Platform effect is clear in the cells (on: every bypass refused; off: every bypass allowed), but the pre-registered control failed. Fix before run 2: unique destination object name per call. Not re-run today (needs another on/off cycle).
- 16:33Z teardown: infra/agents v3a, v3b, G destroyed (4 destroyed; 0 engines left in runtime). 16:35Z infra/ teardown to baseline (lz-5 + v3h-baseline: 85 destroy, 1 change = agent ingress rule removed, 1 add = v3_net compute service back in state; all project_service removals have disable_on_destroy=false) running.
- 16:45Z block 4: infra-v3h agents 1 and 2 destroyed (mcp; 2 destroyed). 16:45:54Z T43 t0 PASS (binding present). p15 >= 17:01Z; p24h >= 2026-11-12T16:46Z (human: keep 24 h, run unattended).
- 17:01Z T43 p15 PASS (binding present at +15 min).
- 16:55-17:15Z teardown retry: gateway, gateway attachment/VPC/DNS, authz policy, remaining services removed (22 destroyed). Left: lzv-psci network attachment (2 stale endpoints from deleted agents, 412 conditionNotMet) + SWP VPC/subnets (no cost); polling for release, then final apply.
- After run 1 (human 2026-11-11): Vertex service agents created up front for runs 2 and 3 (infra/v3h-service-agents.tf, base root so infra-v3h still names no aiplatform role; data and outside: 8 added; both service-agent bindings verified). T40 expected text unchanged. RUN-ORDER-v3h step 0a.
- After run 1 (human 2026-11-11): T44 egress verdict moved to TARGET=internet (https://example.com, as T23) from run 2 on; run.app recorded as observed (header updated before run 2). lib-v3h v3h_query records a run-level VPC-SC refusal as status 403 refused_by=vpc_sc_runtime. Draft plans/v3h-automation.md (unattended runs, no deploy spacing, side-by-side variants, canary-based waits) awaiting approval.
- 16:47Z step close-preflight
- 16:47Z step close-init
- 16:47Z step close-t43-p24h
- 16:47Z T43 p24h (run-1): PASS 
- 16:47Z step close-agent3
- 16:47Z plan v3h-agent3: 1 changes (1 create )
- 16:50Z apply v3h-agent3: Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
- 16:50Z ready: v3h-agent3 after 2 s
- 16:50Z waiting 5 min: 5 min after agent 3 (T43 pre-registered wait)
- 16:55Z step close-t43-agent3
- 16:55Z T43 agent3 (run-1): PASS RESULT T43: PASS
- 16:55Z step close-agent3-off
- 16:55Z plan v3h-agent3-off: 1 changes (1 delete )
- 16:55Z apply v3h-agent3-off: Apply complete! Resources: 0 added, 0 changed, 1 destroyed.
- 16:55Z step t40b-agent1
- 16:55Z plan v3h-agent1: 1 changes (1 create )
- 16:58Z apply v3h-agent1: Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
- 16:58Z ready: v3h-agent1 after 2 s
- 16:58Z step t40b-pre
- 16:58Z T40b pre (run-1): PASS 
- 16:58Z step t40b-drift
- 16:58Z T40b drift (run-1): PASS 
- 16:58Z step t40b-apply
- 16:59Z plan v3h-t40b: 1 changes (1 create )
- 16:59Z apply v3h-t40b: Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
- 16:59Z waiting 7 min: 7 min IAM propagation (T40b pre-registered wait)
- 17:06Z step t40b-call
- 17:06Z T40b call (run-1): PASS 
- 17:06Z step t40b-agent2
- 17:06Z plan v3h-agent2: 1 changes (1 create )
- 17:08Z apply v3h-agent2: Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
- 17:08Z ready: v3h-agent2 after 2 s
- 17:08Z waiting 5 min: 5 min after agent 2 (T40b)
- 17:13Z step t40b-agent2-test
- 17:14Z T40b agent2 (run-1): PASS RESULT T40b: PASS
- 17:14Z step t40b-restore
- 17:14Z plan v3h-t40b-restore: 3 changes (3 delete )
- 17:14Z apply v3h-t40b-restore: Apply complete! Resources: 0 added, 0 changed, 3 destroyed.
- 17:14Z close 1 finished
- 17:14Z step close-redact
- 17:14Z close redaction: redacted 20/30 files; check: checked 30 files, 0 with findings
