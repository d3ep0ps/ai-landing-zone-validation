# v3h gw 2 (2026-11-15), gateway-only (tests/run-v3h.sh gw)

Block 2 only: T53 v2 and T56 v2 (plan 3b, 5c3808a). Expected results: script headers (pre-registered).

## Log
- 07:51Z step preflight
- 07:52Z preflight OK (subset): PROJECT_8 empty, canary OK
- 07:52Z step build
- 07:52Z artifacts: agent_v3 sha256 3dcf5b7c2d4400b3..., agent_g sha256 886d3843fced0a52...
- 07:52Z step b2-infra
- 07:52Z plan b2-infra: 76 changes (75 create 1 delete )
- 07:59Z apply b2-infra failed with a known propagation error; retry 1 of 2 in 180 s (Error: Error waiting to create AuthzPolicy: Error waiting for Creating AuthzPolicy: Error code 10, message: There is another ongoing operation for the same Agen)
- 08:03Z plan b2-infra-retry: 1 changes (1 create )
- 08:05Z apply b2-infra-retry: Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
- 08:05Z step b2-fixtures
- 08:06Z MCP fixture image sha256:5094e4f01caa04e303c4ae825ae2cacb1b63bc37dfeb8b7d64d021269dd38939; lzv-mcp-reg and lzv-mcp-unreg Ready
- 08:06Z replay image sha256:f5ab0acfa8caf3f5ba27df990f9851abbeb610b7e03d2ca81970ebb424cb9699; gateway MCP fixtures rebuilt and deployed
- 08:07Z plan b2-replay: 4 changes (4 create )
- 08:08Z apply b2-replay: Apply complete! Resources: 4 added, 0 changed, 0 destroyed.
- 08:08Z step s2-agents
- 08:08Z plan s2-agents: 6 changes (6 create )
- 08:22Z apply s2-agents: Apply complete! Resources: 6 added, 0 changed, 0 destroyed.
- 08:22Z ready: v3-a after 2 s
- 08:22Z ready: v3-o after 1 s
- 08:22Z ready: v3-x after 1 s
- 08:22Z ready: g after 2 s
- 08:22Z ready: g-optout after 3 s
- 08:22Z step t53
- 08:24Z T53  (gw-2): PASS RESULT T53: PASS
- 08:24Z step t56-calls
- 08:30Z T56 calls (gw-2): PASS 
- 08:30Z waiting 16 min: T56: >= 15 min after its last call (pre-registered late read)
- 08:46Z step t56-late
- 08:46Z T56 late (gw-2): FAIL RESULT T56: FAIL
- 08:46Z step teardown
- 08:46Z teardown: agents
- 08:46Z plan td-agents: 6 changes (6 delete )
- 08:48Z apply td-agents: Apply complete! Resources: 0 added, 0 changed, 6 destroyed.
- 08:48Z teardown: perimeter dry-run, ingress cleared, deny removed (targeted; full refresh fails while enforced)
- 08:49Z plan td-perim: 0 changes ()
- 08:49Z teardown: infra/ back to lz-5 + v3h-baseline
- 08:50Z plan td-infra: 88 changes (1 create 87 delete )
- 09:10Z apply td-infra failed with a known propagation error; retry 1 of 2 in 180 s (Error: Error when reading or editing NetworkAttachment: googleapi: Error 412: Network Attachment with connected endpoints cannot be deleted., conditionNotMet)
- 09:14Z plan td-infra-retry: 35 changes (35 delete )
- 09:34Z STOP: apply td-infra-retry failed: Error: Error when reading or editing NetworkAttachment: googleapi: Error 412: Network Attachment with connected endpoints cannot be deleted., conditionNotMet
- 09:34Z teardown: PSC-I attachment still has endpoints from deleted agents; background poll will finish it (free resources)
- 09:34Z gw run 2 finished
- 09:34Z step redact
- 09:34Z redaction: redacted 9/14 files; check: checked 14 files, 0 with findings (T43 gw-2 redacted at close)

## Analysis (2026-11-15, written after the run; no expected result changed)

- Scope: T53 v3 run 2 and T56 v2 run 3 (schedule row 7b, f85b659). Scripts, fixtures and infra unchanged since run 8 (6b0d1bb).
- T53 v3: PASS, same as run 8. Control 200 (auth=id_token_unbound, cnf_present=false); unregistered_mcp, example_ip (connected to the gateway address in the reserved Class E range 240/4) and storage_api each refused by the gateway (403).
- T56 v2: FAIL, same as gw 1 and run 8. 13 calls; one unregistered_echo call had no tool result and is excluded as pre-registered; 4 of 12 usable calls had no `gateway_requests` record at the late read (registered_echo 1 of 5, unregistered_echo 3 of 4; inject_response 3 of 3 recorded). Every 403 record showed DENIED; no late-only records. Run 8 missed 9 of 13: the share missing varies between runs.
- Teardown: the infra apply stopped twice on HTTP 412 (PSC-I attachment with endpoints of deleted agents; results.md v3h Deviations 14). Paid resources after teardown (09:35Z, runtime project, direct reads): 0 agent gateways, 0 engines, 0 SWP gateways, 0 addresses, 0 forwarding rules, 0 routers. Left in infra/ state: the PSC-I attachment and the restricted-googleapis route (both free); a background poll deletes the attachment. The MCP fixture services remain (min instances 0).
