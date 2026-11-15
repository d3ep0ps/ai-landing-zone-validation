# v3h run 2 (2026-11-11), orchestrated (tests/run-v3h.sh)

Project: data (label r2). Plan: plans/v3h-automation.md. Expected results: script headers (pre-registered).

## Log
- 20:15Z step preflight
- 20:15Z preflight OK: PROJECT_8 empty, step 0a bindings present in PROJECT_10, canary OK
- 20:15Z step build
- 20:15Z artifacts: agent_v3 sha256 a99dfe1923e69667..., agent_g sha256 22f2726f25e3bf98...
- 20:15Z step v3h-s0
- 20:15Z plan v3h-s0: 10 changes (10 create )
- 20:16Z apply v3h-s0: Apply complete! Resources: 10 added, 0 changed, 0 destroyed.
- 20:16Z step t40-before
- 20:16Z T40 before (run-2): PASS 
- 20:16Z step t42-before
- 20:16Z T42 before (run-2): PASS 
- 20:16Z step agent1
- 20:16Z plan v3h-agent1: 1 changes (1 create )
- 20:20Z apply v3h-agent1: Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
- 20:20Z step b2-infra
- 20:21Z plan b2-infra: 75 changes (74 create 1 delete )
- 20:23Z apply b2-infra failed with a known propagation error; one retry in 180 s (Error: Error waiting to create AgentGateway: Error waiting for Creating AgentGateway: Error code 3, message: Config validation failed)
- 20:27Z plan b2-infra-retry: 3 changes (3 create )
- 20:32Z STOP: apply b2-infra-retry failed: Error: Error waiting to create AuthzPolicy: Error waiting for Creating AuthzPolicy: Error code 10, message: There is another ongoing operation for the same AgentGateway: projects/PROJECT_NUMBER_7/location
- 20:32Z run stopped (rc=1) with paid resources up: teardown
- 20:32Z teardown: agents
- 20:32Z plan td-agents: 0 changes ()
- 20:32Z teardown: perimeter dry-run, ingress cleared, deny removed (targeted; full refresh fails while enforced)
- 20:32Z plan td-perim: 0 changes ()
- 20:32Z teardown: infra/ back to lz-5 + v3h-baseline
- 20:33Z plan td-infra: 82 changes (1 create 81 delete )
- 20:53Z STOP: apply td-infra failed: Error: Error when reading or editing NetworkAttachment: googleapi: Error 412: Network Attachment with connected endpoints cannot be deleted., conditionNotMet
- 20:53Z teardown after stop FAILED: human check needed (agents, gateway, SWP)
- 20:54Z step b2-infra
- 20:55Z plan b2-infra: 75 changes (74 create 1 delete )
- 21:01Z apply b2-infra failed with a known propagation error; retry 1 of 2 in 180 s (Error: Error waiting to create AuthzPolicy: Error waiting for Creating AuthzPolicy: Error code 10, message: There is another ongoing operation for the same Agen)
- 21:04Z plan b2-infra-retry: 1 changes (1 create )
- 21:07Z apply b2-infra-retry: Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
- 21:07Z step t40-after
- 21:07Z T40 after (run-2): PASS RESULT T40: PASS
- 21:07Z step t42-after
- 21:07Z T42 after (run-2): PASS RESULT T42: PASS
- 21:07Z step t41-before
- 21:07Z T41 before (run-2): PASS 
- 21:07Z step agent2
- 21:07Z plan v3h-agent2: 1 changes (1 create )
- 21:10Z apply v3h-agent2: Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
- 21:10Z step b2-fixtures
- 21:10Z replay image sha256:882586d3a52c59bf11a0f6f162d00ad0ed70f1f92fe046066addf26b3d82301f; gateway MCP fixtures rebuilt and deployed
- 21:11Z plan b2-replay: 3 changes (3 create )
- 21:12Z apply b2-replay: Apply complete! Resources: 3 added, 0 changed, 0 destroyed.
- 21:12Z waiting 3 min: 5 min after agent 2 (T41 pre-registered wait)
- 21:15Z step t41-after
- 21:15Z T41 after (run-2): PASS RESULT T41: PASS
- 21:15Z step agents12-off
- 21:15Z plan v3h-agents12-off: 2 changes (2 delete )
- 21:15Z apply v3h-agents12-off: Apply complete! Resources: 0 added, 0 changed, 2 destroyed.
- 21:15Z step t43-t0
- 21:15Z T43 t0 (run-2): PASS 
- 21:15Z step b2-agents
- 21:15Z plan b2-agents: 5 changes (5 create )
- 21:27Z apply b2-agents: Apply complete! Resources: 5 added, 0 changed, 0 destroyed.
- 21:27Z ready: v3a after 2 s
- 21:27Z ready: v3o after 2 s
- 21:27Z ready: g after 3 s
- 21:27Z ready: g-optout after 3 s
- 21:27Z step t47
- 21:27Z T47 s1 (run-2): PASS 
- 21:28Z T47 s2 (run-2): FAIL 
- 21:29Z T47 s3 (run-2): PASS 
- 21:30Z T47 s4 (run-2): FAIL RESULT T47: FAIL
- 21:30Z step t48
- 21:30Z T48 bound (run-2): PASS 
- 21:31Z T48 optout (run-2): PASS RESULT T48: PASS
- 21:31Z step t46
- 21:31Z T46  (run-2): NOT_TESTED RESULT T46: NOT_TESTED
- 21:31Z step t44-pre
- 21:31Z T44 pre (run-2): PASS 
- 21:31Z step t43-p15
- 21:31Z T43 p15 (run-2): PASS 
- 21:31Z step b3-enforce
- 21:31Z plan b3-enforce: 1 changes (1 update )
- 21:32Z apply b3-enforce: Apply complete! Resources: 0 added, 1 changed, 0 destroyed.
- 21:32Z canary: perimeter 'enforced' live after 32 s
- 21:32Z step b3-agents
- 21:32Z plan b3-agents: 4 changes (4 create )
- 21:39Z apply b3-agents: Apply complete! Resources: 4 added, 0 changed, 0 destroyed.
- 21:39Z ready: v3-b after 2 s
- 21:39Z ready: v3-a_psci after 2 s
- 21:39Z ready: v3-b_psci after 2 s
- 21:39Z step t44-noingress
- 21:40Z T44 noingress (run-2): PASS 
- 21:40Z step b3-ingress-deny
- 21:40Z plan b3-ingress-deny: 2 changes (1 create 1 update )
- 21:40Z apply b3-ingress-deny: Apply complete! Resources: 1 added, 1 changed, 0 destroyed.
- 21:41Z canary: perimeter 'ingress' live after 32 s
- 21:41Z step t44-ingress
- 21:42Z T44 ingress (run-2): INCONCLUSIVE RESULT T44: INCONCLUSIVE
- 21:42Z waiting 9 min: IAM deny propagation (fixed)
- 21:51Z step t45-on
- 21:51Z T45 on (run-2): PASS 
- 21:51Z step b3-off
- 21:52Z plan b3-off: 2 changes (1 delete 1 update )
- 21:52Z apply b3-off: Apply complete! Resources: 0 added, 1 changed, 1 destroyed.
- 21:53Z canary: perimeter 'open' live after 33 s
- 21:53Z waiting 10 min: IAM deny removal propagation (fixed)
- 22:02Z step t45-off
- 22:03Z T45 off (run-2): PASS RESULT T45: PASS
- 22:03Z step teardown
- 22:03Z teardown: agents
- 22:03Z plan td-agents: 9 changes (9 delete )
- 22:05Z apply td-agents: Apply complete! Resources: 0 added, 0 changed, 9 destroyed.
- 22:05Z teardown: perimeter dry-run, ingress cleared, deny removed (targeted; full refresh fails while enforced)
- 22:06Z plan td-perim: 1 changes (1 update )
- 22:06Z apply td-perim: Apply complete! Resources: 0 added, 1 changed, 0 destroyed.
- 22:06Z teardown: infra/ back to lz-5 + v3h-baseline
- 22:07Z plan td-infra: 86 changes (1 create 85 delete )
- 22:27Z apply td-infra failed with a known propagation error; retry 1 of 2 in 180 s (Error: Error waiting for Deleting AuthzPolicy: Error code 10, message: There is another ongoing operation for the same AgentGateway: projects/PROJECT_NUMBER_7/locat)
- 22:31Z plan td-infra-retry: 30 changes (30 delete )
- 22:51Z STOP: apply td-infra-retry failed: Error: Error when reading or editing NetworkAttachment: googleapi: Error 412: Network Attachment with connected endpoints cannot be deleted., conditionNotMet

## Results (verdicts from result.json; expected results unchanged)

| Test | Run 2 | Run 1 | Note |
|---|---|---|---|
| T40 | PASS | FAIL (F1) | Step 0a (Vertex service agents created up front) isolated the platform grant |
| T41 | PASS | INCONCLUSIVE | Troubleshooter API available |
| T42 | PASS | PASS | |
| T43 | t0 PASS, p15 PASS; p24h/agent3 open | same | `tests/run-v3h.sh close 2` at >= 2026-11-12T21:16Z |
| T44 | INCONCLUSIVE | FAIL | A (deployed before enforcement): own model call refused by VPC-SC at runtime also with the ingress rule (F4 again). B (deployed after enforcement): example.com blocked, model and run.app 200 |
| T45 | PASS (on, off) | INCONCLUSIVE | Side-by-side engines (a_psci/b_psci on, a/b off) |
| T46 | NOT_TESTED | NOT_TESTED | Documented tier, as pre-registered |
| T47 | FAIL (s1 PASS, s2 FAIL, s3 PASS, s4 FAIL) | FAIL | F3 repeats in a second project: bound token through the gateway returned 200 |
| T48 | PASS (bound, optout) | PASS (run-1-r3) | First attempt |

## Deviations (orchestrator, not test logic)

- D1 20:32Z: block-2 apply stopped after one retry (gateway "Config validation failed", then "another ongoing operation" on the AuthzPolicy). EXIT trap tore down block-2 infra; steps up to agent1 kept. Fix: two retries for the known propagation errors. Resumed 20:54Z; the retry succeeded at 21:07Z.
- D2: the resume reset the agent-1 time mark (only a longer wait before T40 after, 21:07Z vs >= 20:25Z). Fixed: marks are kept on resume.
- D3 21:33Z: readiness probe changed while the run was going (file swapped, running copy unaffected) to also accept a VPC-SC session refusal as "serving" (either answer counts; it never waits for the tested outcome). Not needed in this run: the probe got 200 for B, a_psci and b_psci (deployed after enforcement, no ingress rule yet) within 2 s.
- D4: canary timings: enforced 32 s, ingress 32 s, open 33 s after apply (run 1 used fixed 15 min waits).
- D5 teardown: all paid resources removed (9 agent-root resources, gateway, SWP, Cloud Run replay, targets). infra/ teardown stopped again at the PSC-I attachment from run 1 (HTTP 412, 2 connected endpoints); left: that VPC (network, attachment, 2 subnets) and 4 API enablements, no cost. The redaction step was run by hand after the stop.

## Limitation found after the run (2026-11-12, recorded before run 3)

- T44 ingress ran about 1 min after the ingress apply (canary saw the rule live on the API in 32 s); run 1's ingress stage ran 15 min after it. Agent A worked in run 1 and was refused (VPC-SC at session creation) in run 2. The canary is not shown to reflect the agent runtime's session path, so run 2's T44 INCONCLUSIVE may be a propagation-timing artefact. T44 v2 / T44b (plan section 3b) take the ingress verdict at +15 min and record +1 min as an observation. T44 runs 1-2 are labelled exploratory.
- 21:17Z step close-preflight
- 21:17Z step close-init
- 21:17Z step close-t43-p24h
- 21:17Z T43 p24h (run-2): PASS 
- 21:17Z step close-agent3
- 21:17Z plan v3h-agent3: 1 changes (1 create )
- 21:20Z apply v3h-agent3: Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
- 21:20Z ready: v3h-agent3 after 3 s
- 21:20Z waiting 5 min: 5 min after agent 3 (T43 pre-registered wait)
- 21:25Z step close-t43-agent3
- 21:25Z T43 agent3 (run-2): PASS RESULT T43: PASS
- 21:25Z step close-agent3-off
- 21:25Z plan v3h-agent3-off: 1 changes (1 delete )
- 21:25Z apply v3h-agent3-off: Apply complete! Resources: 0 added, 0 changed, 1 destroyed.
- 21:25Z close 2 finished
- 21:25Z step close-redact
- 21:25Z close redaction: redacted 8/14 files; check: checked 14 files, 0 with findings
