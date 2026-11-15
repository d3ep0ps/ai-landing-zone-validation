# v3h run 5 (2026-11-13), subset (tests/run-v3h.sh subset)

No per-run project (block 2/3 only, plan 3b scheduling). Expected results: script headers (pre-registered).

## Log
- 09:53Z step preflight
- 09:53Z preflight OK (subset): PROJECT_8 empty, canary OK
- 09:53Z step build
- 09:53Z artifacts: agent_v3 dep (T45d) sha256 5ca424cc40eab162...
- 09:53Z artifacts: agent_v3 sha256 3dcf5b7c2d4400b3..., agent_g sha256 b8d524168a5f1428...
- 09:53Z step b2-infra
- 09:54Z plan b2-infra: 75 changes (74 create 1 delete )
- 09:55Z apply b2-infra failed with a known propagation error; retry 1 of 2 in 180 s (Error: Error waiting to create AgentGateway: Error waiting for Creating AgentGateway: Error code 3, message: Config validation failed)
- 09:59Z plan b2-infra-retry: 3 changes (3 create )
- 10:04Z apply b2-infra-retry failed with a known propagation error; retry 2 of 2 in 180 s (Error: Error waiting to create AuthzPolicy: Error waiting for Creating AuthzPolicy: Error code 10, message: There is another ongoing operation for the same Agen)
- 10:08Z plan b2-infra-retry-retry: 1 changes (1 create )
- 10:11Z apply b2-infra-retry-retry: Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
- 10:11Z step b2-fixtures
- 10:12Z replay image sha256:870af3d1958d2889a26f8b078d660f0f5cc7a5f9ed7e5a66a31679b94feb12e9; gateway MCP fixtures rebuilt and deployed
- 10:12Z plan b2-replay: 4 changes (4 create )
- 10:13Z apply b2-replay: Apply complete! Resources: 4 added, 0 changed, 0 destroyed.
- 10:13Z step s2-agents
- 10:13Z plan s2-agents: 6 changes (6 create )
- 10:27Z apply s2-agents: Apply complete! Resources: 6 added, 0 changed, 0 destroyed.
- 10:27Z ready: v3-a after 2 s
- 10:27Z ready: v3-o after 2 s
- 10:27Z ready: v3-x after 2 s
- 10:27Z ready: g after 2 s
- 10:27Z ready: g-optout after 2 s
- 10:27Z step t48b
- 10:27Z T48b  (run-5): PASS RESULT T48b: PASS
- 10:27Z step t50-main
- 10:27Z T50 main (run-5): FAIL 
- 10:27Z step t52-default
- 10:28Z T52 default (run-5): PASS 
- 10:28Z step t52-grant
- 10:29Z STOP: plan t52-grant has unexpected changes (not applied): create google_project_iam_member.v3h_t52_context_editor[0];
- 10:29Z run stopped (rc=1) with paid resources up: teardown
- 10:29Z teardown: agents
- 10:29Z plan td-agents: 6 changes (6 delete )
- 10:31Z apply td-agents: Apply complete! Resources: 0 added, 0 changed, 6 destroyed.
- 10:31Z teardown: perimeter dry-run, ingress cleared, deny removed (targeted; full refresh fails while enforced)
- 10:31Z plan td-perim: 0 changes ()
- 10:31Z teardown: infra/ back to lz-5 + v3h-baseline
- 10:33Z plan td-infra: 87 changes (1 create 86 delete )
- 10:53Z apply td-infra failed with a known propagation error; retry 1 of 2 in 180 s (Error: Error when reading or editing NetworkAttachment: googleapi: Error 412: Network Attachment with connected endpoints cannot be deleted., conditionNotMet)
- 10:57Z plan td-infra-retry: 30 changes (30 delete )
- 11:17Z STOP: apply td-infra-retry failed: Error: Error when reading or editing NetworkAttachment: googleapi: Error 412: Network Attachment with connected endpoints cannot be deleted., conditionNotMet
- 11:17Z teardown: PSC-I attachment still has endpoints from deleted agents; background poll will finish it (free resources)

## Stop analysis (2026-11-13, written after the run; no expected result changed)
- Wrapper exit: rc=1 at 11:17:05Z. Recorded before the stop: T48b v2 PASS, T50 main FAIL (b1 409, as run 4; T50c shows b1 does not discriminate), T52 default PASS.
- Stop: plan t52-grant held only the intended change (create google_project_iam_member.v3h_t52_context_editor[0]) but the allowlist pattern omitted the count index `[0]`, so the safety check refused it. Harness defect, first reached in this run. Fixed (pattern accepts an optional `[0]`); tooling fix, recorded in plan section 3b.
- Teardown: no paid resources left (0 engines, 0 agent gateways, 0 SWP gateways, 0 addresses). Known free PSC-I leftovers (412); background poll deletes the attachment.
- Redaction run by hand (the orchestrator redacts only on success).
- Next: run 7 (subset 4, attempt 3; human go 11-13). Run number 6 is not used.
