# Evidence review: v3h report text (fresh-context audit, 2026-11-14)

Scope: results.md "## v3h results" (lines 266-345), limitations.md "## v3h limitations" (lines 116-140), claims-register.md S11, C30-C36, F26-F35, X15-X20 and the v3h sentence in X1.
Method: read-only comparison against `evidence/T4x-T5x/*/result.json`, selected `output.txt` / `stages/*.json`, run logs `evidence/runs/run-v3h-1,4,5,7.md`, `gw-1.md`, `t57-1.md`, `infra/v3h-t52.tf`, `notes/doc-verification-v2-B-401.md`. The review was stopped early on request; see "Not reviewed".

## Verified as correct

- Verdict counts (results.md:311, claims-register.md:21 S11): 60 result.json files; less the 6 superseded (T44 run-1 FAIL, T44 run-2 INCONCLUSIVE, T48b run-4 INCONCLUSIVE, T53 run-7 FAIL, T53 gw-1 INCONCLUSIVE, T56 run-7 FAIL) = 54: 35 PASS, 9 FAIL, 7 INCONCLUSIVE, 3 NOT_TESTED. Per-test breakdown matches.
- The T56 numbers (results.md:304, 342; F33): run 8 missing=9 (registered_echo 3/5, inject_response 3/3, unregistered_echo 3/5), 403 without DENIED=0, late-only=0; gw-1 and run-7 missing=1 of 5 denied calls.
- T57 (results.md:305, 343; F32): before / +1 / +5 min match (fs-after1.json), enforce=true, restore has the same createTime and a new updateTime; t57-1.md:27 supports the run 6-7 sentence.
- T44b 400 with vpcsc=1 in runs 3, 7 and 8; +1 and +15 min A=200 (result.json).
- T51 cells (results.md:300, 345; C36; limitations.md:124) match runs 7 and 8; the Troubleshooter attributes the result to the deny.
- T50/T50c: setIamPolicy 409, patch 403, deny stage 403 in runs 7 and 8; partial runs 4 and 5 (stages/main.json, run logs) match; the T50c canary held projects.get only and got 409.
- T47 (google-auth 2.62.1), T47r (2.62.2, unpinned), T47r2 (2.62.0, run-6 set) versions and outcomes; T48 agents ran google-auth 2.62.1 (T48/*/output.txt:7).
- T45 run-1-r2 cause (limitations.md:123) matches run-v3h-1.md:61; SWP 403 matches T45/run-2/output.txt:491 ("Tunnel connection failed: 403 Forbidden").
- gw 1 login expiry ~14:35Z, about 3 h (gw-1.md:28, 78); T53/T56 fixture 401 cause (gw-1.md:84) supports F30 and limitations.md:130.
- The doc statement in Findings 34 (the gateway terminates mTLS; DPoP re-authenticates) matches notes/doc-verification-v2-B-401.md:10. "Samples set the opt-out" (X17) matches line 36 of that file.
- Banned wording: none in scope. The only hit is claims-register.md:109 (X2, the rule itself).

## HIGH (wrong or unsupported claim)

H1. claims-register.md:95 (F28): "Granting `roles/aiplatform.agentContextEditor` to one agent let it list and read another agent's sessions".
Contradicting evidence: infra/v3h-t52.tf:11-15 grants the role on the project to `principalSet://agents.global.org-.../attribute.platformContainer/aiplatform/projects/N`, which covers every agent in the runtime project. The T52 run-7/run-8 result.json `control` says "project-level agentContextEditor on the agents principal set". No single-agent grant was tested.
Fix: "Granting `roles/aiplatform.agentContextEditor` on the project to the agents principal set (all agents in the project) let one agent list and read another agent's sessions and memories (query still 403)." Also adjust the qualification: per-agent grants were not tested.

H2. claims-register.md:58 (C32): "(own-access controls 200)".
Contradicting evidence: in T52 run-7 and run-8 result.json, `control` is "the operator's same calls 200", and `actual` shows "controls 200/200/200/200" for the operator. Agent B's access to its own sessions was not tested (the same applies to stages/default.json in run 5).
Fix: replace with "(the operator's same calls 200)".

H3. limitations.md:127: "T44 v2, T44b, T49 and T48b v2 ran in runs 3, 7 and 8 ... with the setup unchanged". The T44 v2 pre-registration also says "3 runs unchanged".
Contradicting evidence: the agent_v3 artifact changed between runs. T44/run-3/result.json shows `artifact sha256 3237c1dc5fb4...`; T44/run-7 and run-8 show `3dcf5b7c2d44...` (run-v3h-3.md:9 vs run-v3h-7.md:10 and run-v3h-8.md:10). Agent G also changed between runs 7 and 8 (b8d52416... vs 886d3843..., run-v3h-8.md:10; expected, from the T53 v3 fix). No deviation records the agent_v3 change or says whether it touches the T44, T44b, T48b or T49 code paths.
Fix: state the artifact change and its commit (likely the efd02aa T48b v2 / T50 fixes) in a new deviation. Say whether the T44/T44b/T49 code paths changed. Replace "setup unchanged" with "infrastructure unchanged; agent artifact rebuilt (see deviation N)".

## MEDIUM (missing qualification)

M1. results.md:282 (T40 expectation "audit shows a Google-managed identity"), F26 at claims-register.md:93. The audit actor in all three runs is redacted as `USER_5@example.com` (T40/run-1..3/result.json `actual`; T40/run-2/output.txt:390). The operator is USER_1 (T40/run-2/output.txt:370). Only the run log asserts "(Google-managed)" (run-v3h-1.md:17). After redaction a reader cannot check that, and the verdict does not evaluate the actor. Fix: "the actor differs from the operator; that it is a Google-managed identity is recorded in the run log and hidden by redaction (or keep the domain unredacted)".

M2. results.md:336 (Findings 34), claims-register.md:98 (F31): "a certificate-bound token was accepted". T47 `actual` does not record whether the token was bound. Binding is shown by T49, which first ran in run 3, so runs 1 and 2 of T47 have no same-run evidence of binding. Fix: "bound per T49 (same agent G and package set) in run 3 and later; runs 1-2 inferred".

M3. results.md:340 (Findings 38: "In every run all three attempts ... were refused or did not connect"), claims-register.md:59 (C33: "the two earlier runs also show every attempt refused"). T53/run-7/result.json records `example_ip: landed`. The reclassification is post-run analysis (run-v3h-7.md:123): the connected address was the gateway's 240/4 address. That analysis partly relies on "no gateway record names example.com", and T56 shows that log misses records. Fix: "run 7's script recorded example_ip as landed; post-run analysis of the connected address attributes the answer to the gateway (run-v3h-7.md:123)".

M4. results.md:342 (Findings 40 "three runs"), claims-register.md:100 (F33 "three runs"), claims-register.md:123 (X16 "T56 FAIL in three runs"). One of the three is the superseded T56 v1 (run 7). results.md:278 says versions are not counted together. Fix: "two runs of v2 (gw 1, run 8) and the superseded v1 run 7".

M5. results.md:311 (counts) and claims-register.md:21 (S11). The 35 PASS / 9 FAIL include rows that are diagnostics, not control outcomes:
- T47r2 PASS = "clean outcome either way" (no prediction);
- T50c PASS = confirms that T50 b1 does not discriminate;
- T47r FAIL = "did not reproduce, cause unknown".
Fix: add one sentence saying these three verdicts are diagnostic, or report the counts with and without them.

M6. results.md:321 (Deviations 5). The run log says the agent's own call lacked the certificate, not "the replay service call" (run-v3h-1.md:32). The first attempt was a transient 503, not the fixture (line 30). The second fix, disabling invoker IAM on the replay service (`v3h_replay_auth=false`, line 35), is omitted, yet it is a material fixture change for T48 and later runs. Fix: correct the attribution and add the invoker change. Also correct results.md:295 ("after two INCONCLUSIVE attempts (fixture ...)": one transient, one fixture).

M7. results.md:301, 341 (T52 table and Findings 39) do not say who received the grant. Add "on the project to the agents principal set" (see H1). Without it, "no per-agent scoping was seen" reads as a finding about a per-agent grant.

M8. claims-register.md:62 (C36): the qualification gives no run count. Add "two runs (7, 8)".

## LOW (wording / precision)

L1. results.md:290 (T45d "Platform on: 403, no connection, 403"). The b-dep cell was the SWP proxy refusing the tunnel with 403 (T45d/run-7/output.txt:471, "Tunnel connection failed: 403 Forbidden"), not "no connection". Fix: "403, SWP 403, 403".
L2. results.md:311 lists "T52 (2 PASS)" under "mixed". T52 passed in every run; move it to "PASS in every run".
L3. limitations.md:121 (T41 run 1 "not enabled on the project"). The error names PROJECT_6 (the gcloud quota/config project), not the test project PROJECT_9 (T41/run-1/result.json `reason`). Fix: "not enabled on the gcloud quota project".
L4. results.md:271 and limitations.md:138 say the partial T50/T52 stages are only in run logs. They are also in evidence/T50/run-4/stages/main.json, evidence/T50/run-5/stages/main.json and evidence/T52/run-5/stages/default.json. Link those.
L5. claims-register.md:57 (C31): "With the token-binding opt-out, the replay succeeded (200)" follows the T48b clause, but T48b has no opt-out stage. Fix: "(T48 and T49 opt-out stages)".
L6. results.md:298 (T50 table). The pre-registered part a covers "the project and the folder"; the report and C34 mention only the project. Either confirm that the folder check ran or say it was project only.

## Not reviewed (stopped on request)

- Pre-registered text in plans/v3-harness-boundary-tests.md sections 3 and 3b compared with the result.json `expected` fields (only result.json `expected` was used).
- Commit hashes in Deviations 2, 3, 6-12, 14 (831b29a, b4db69f, 54f8c34, 3426da1, efd02aa, 820b9b4, 9b18633, 5c3808a, f445129, f4beb25, 2033224, 5faaf36); Deviations 2, 7, 11 (HTTP 412 build logs), 14, 15.
- limitations.md:126 (T54 not scheduled), :128, :129 (opt-out stage list, D9), :133, :136, :139 ("fixture services remain deployed, min instances 0"), :140 ("all 60 result.json record gcloud 590.0.1 / Terraform 1.17.1 / provider 8.8.0"; spot-checked in 4 files only).
- T43 run 2, T42 runs 2-3, T44 run-7 pre stage, T49 opt-out details, T46 doc-evidence.txt.
- Findings 33 "not shown" text; C30, C35 and F34 qualifications in detail; F35 (build logs); X1 v3h sentence, X15, X17-X20 wording beyond the checks above.
- run logs run-v3h-2.md, run-v3h-3.md (beyond the artifact line), run-v3h-8.md (beyond the artifact lines), t47r-1.md, t47r2-1.md.

## Resolution (2026-11-14, main session)
- H1, H2, H3: confirmed and fixed (F28 and T52 text name the project-level grant to the agents principal set; C32 control is the operator's calls; limitations no longer say "setup unchanged"; new results.md v3h Deviations 16 records the agent_v3 tarball change in efd02aa, T48b v2 code only, and agent G's T53 v3 change).
- M1-M8, L1-L6: fixed as proposed. L6: T50 part a covered project and folder; one folder permission name was rejected as not valid at folder level (400), now stated. M5: counts also given without the three diagnostic verdicts (51 results: 33 PASS, 8 FAIL, 7 INCONCLUSIVE, 3 NOT_TESTED).
- Not-reviewed items checked by the main session: all 12 commit hashes in the deviations exist; all 60 v3h result.json files record gcloud 590.0.1, Terraform 1.17.1, provider 8.8.0; fixture services min instances 0 (describe 2026-11-14); T47r2 records iapPolicyVersion "not shown"; T44 run 1 opt-out (D9) in run-v3h-1.md. Pre-registered expected text is written by each script from its header, so result.json `expected` equals the header text.
- Redaction-checker (2026-11-14): reports and v3h evidence clean. Tracked infra files infra/profiles/v3h-block2.tfvars, v3h-block3.tfvars, infra/v4-deploy.sh, infra/agents/agent-o.tf hold real identifiers; they must be redacted or excluded in the next public export (git archive). Not yet in the public copy (10-30).
