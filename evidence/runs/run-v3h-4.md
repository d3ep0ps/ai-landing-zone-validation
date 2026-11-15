# v3h run 4 (2026-11-13), subset (tests/run-v3h.sh subset)

No per-run project (block 2/3 only, plan 3b scheduling). Expected results: script headers (pre-registered).

## Log
- 07:28Z step preflight
- 07:28Z preflight OK (subset): PROJECT_8 empty, canary OK
- 07:28Z step build
- 07:28Z artifacts: agent_v3 dep (T45d) sha256 7c6564d86cebbbeb...
- 07:28Z artifacts: agent_v3 sha256 3237c1dc5fb4510a..., agent_g sha256 b8d524168a5f1428...
- 07:28Z step b2-infra
- 07:29Z plan b2-infra: 75 changes (74 create 1 delete )
- 07:35Z apply b2-infra failed with a known propagation error; retry 1 of 2 in 180 s (Error: Error waiting to create AuthzPolicy: Error waiting for Creating AuthzPolicy: Error code 10, message: There is another ongoing operation for the same Agen)
- 07:39Z plan b2-infra-retry: 1 changes (1 create )
- 07:42Z apply b2-infra-retry: Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
- 07:42Z step b2-fixtures
- 07:43Z replay image sha256:24dcab814fc71640740842d50acb10dcd8cfd89d47eb56d50b85561f953f685d; gateway MCP fixtures rebuilt and deployed
- 07:44Z plan b2-replay: 4 changes (4 create )
- 07:44Z apply b2-replay: Apply complete! Resources: 4 added, 0 changed, 0 destroyed.
- 07:44Z step s2-agents
- 07:44Z plan s2-agents: 6 changes (6 create )
- 07:58Z apply s2-agents: Apply complete! Resources: 6 added, 0 changed, 0 destroyed.
- 07:58Z ready: v3-a after 2 s
- 07:58Z ready: v3-o after 2 s
- 07:58Z ready: v3-x after 1 s
- 07:58Z ready: g after 2 s
- 07:58Z ready: g-optout after 3 s
- 07:58Z step t48b
- 07:58Z T48b  (run-4): INCONCLUSIVE RESULT T48b: INCONCLUSIVE
- 07:58Z step t50-main
- 07:58Z T50 main (run-4): FAIL 
- 07:58Z step t52-default
- 07:59Z STOP: T52 default aborted: ABORT: operator could not create a session on A (HTTP 200)
- 07:59Z run stopped (rc=1) with paid resources up: teardown
- 07:59Z teardown: agents
- 07:59Z plan td-agents: 6 changes (6 delete )
- 08:01Z apply td-agents: Apply complete! Resources: 0 added, 0 changed, 6 destroyed.
- 08:01Z teardown: perimeter dry-run, ingress cleared, deny removed (targeted; full refresh fails while enforced)
- 08:01Z plan td-perim: 0 changes ()
- 08:01Z teardown: infra/ back to lz-5 + v3h-baseline
- 08:02Z plan td-infra: 87 changes (1 create 86 delete )
- 08:22Z apply td-infra failed with a known propagation error; retry 1 of 2 in 180 s (Error: Error waiting for Deleting AuthzPolicy: Error code 10, message: There is another ongoing operation for the same AgentGateway: projects/PROJECT_NUMBER_7/locat)
- 08:26Z plan td-infra-retry: 35 changes (35 delete )
- 08:46Z STOP: apply td-infra-retry failed: Error: Error when reading or editing NetworkAttachment: googleapi: Error 412: Network Attachment with connected endpoints cannot be deleted., conditionNotMet
- 08:46Z teardown: PSC-I attachment still has endpoints from deleted agents; background poll will finish it (free resources)

## Stop analysis (2026-11-13, written after the run; no expected result changed)
- Wrapper exit: rc=1 at 08:46:50Z. The queued close 3 / subset 5 job stood down (it required subset 4 rc=0).
- Teardown: no paid resources left (0 engines, 0 agent gateways, no SWP gateway, forwarding rules or addresses). Left: the known free PSC-I attachment (412, endpoints of deleted agents), its VPC/subnets, v3_net VPC/subnet/route; background poll deletes the attachment.
- Redaction: run by hand with tools/redact.py (the orchestrator redacts only on success): 9/12 files redacted, check 0 findings.
- T52 default: ABORT is a harness defect, not a control outcome. The operator's session create returned HTTP 200 with a session id; `sed -n '/^\{/,$p'` fails on macOS sed ("RE error: braces not balanced"), so the id was never parsed. T52 not run (no verdict).
- T50 main: FAIL stands as pre-registered (agent setIamPolicy, stale etag = 409 ABORTED, not 403; patch own engine = 403). Finding: the same agent's testIamPermissions shows no permission granted, so the 409 most likely means the API checks the etag before authorization, which makes attempt b1 non-discriminating. Not yet shown; needs a pre-registered control with a principal that has no permission. The same sed defect blanked the operator controls' status text (codes 409/200 were read correctly; the verdict uses codes only). Stage deny not run.
- T48b: INCONCLUSIVE stands. X's token over Y's session gave no status: RefreshError. Most likely cause (fixture): google-auth AuthorizedSession refreshes on a 401 and a bare token cannot refresh, so a 401 refusal was masked. Not shown from this evidence.
- Not run: T44 v2, T44b, T49 (run 2), T45d, T51, T52, T53, T55, T56 (run 1). A resume of run 4 would skip infra/agent steps that teardown removed, so the remaining tests need a fresh run number.
