# v3h run order (T40-T48), per run (DRAFT, scripts never run)

Plan: [plans/v3-harness-boundary-tests.md](../plans/v3-harness-boundary-tests.md) section 4. Run IDs `run-1`, `run-2`, `run-3` (retry `run-1-r2`); T40b one run, `run-1`, in its own project.
Rules: the human applies every Terraform change, deploys agents and approves each platform toggle; scripts only read, plan and query. Terraform toggles for infra-v3h go in `infra-v3h/terraform.tfvars` so `terraform plan` inside the scripts matches reality (extra plan args: `V3H_PLAN_ARGS`). Label of the per-run project = `r<N>` from `RUN_ID` (override with `V3H_RUN`). One agent deploy per apply, 30 minutes apart. Logins expire in about 1 hour: refresh before each block. Tests with a wait export `V3H_WAITED_5MIN=yes` after it.
Helper: `tests/lib-v3h.sh` (sourced by T40-T48; `tests/lib.sh` header regex now also accepts a lowercase `b` suffix, for T40b).

## Block 1: per-run project (infra-v3h, state `infra-v3h/state/rN.tfstate`)

| # | Who | Action | Wait |
|---|---|---|---|
| 0 | human | Build the tarball once (record sha256); apply infra-v3h, all toggles off (project, operator IAM, no agents) | 1 h after the previous project creation |
| 0a | human | Vertex service agents exist in the run's project with their roles (infra/ `v3h_vertex_service_agent_projects`, in profiles/v3h-baseline.tfvars; data and outside applied 2026-11-11). Check before T40 `before`: both service-agent bindings present | |
| 1 | script | `RUN_ID=run-N tests/T40.sh before` (snapshot, plan exit 0) | |
| 2 | script | `RUN_ID=run-N tests/T42.sh before` (needs conftest; positive control + real plan gate) | |
| 3 | human | `deploy_agent_1=true`, apply (agent 1 deploy) | 5 min |
| 4 | script | `V3H_WAITED_5MIN=yes RUN_ID=run-N tests/T40.sh after` (diff, plan, audit-log query) | |
| 5 | script | `RUN_ID=run-N tests/T42.sh after` | |
| 6 | script | `RUN_ID=run-N tests/T41.sh before` | |
| 7 | human | `deploy_agent_2=true`, apply | 30 min after agent 1 deploy; then 5 min |
| 8 | script | `V3H_WAITED_5MIN=yes RUN_ID=run-N tests/T41.sh after` (diff, Troubleshooter, agent 2 call) | |

## Block 2: gateway and replay (infra/agents in the runtime project; done after block 1 of the same run)

Prerequisites: gateway and agent G as in RUN-ORDER-run9.md (9-0a..9-0c); agents v3a/v3b from `tests/fixtures/agent_v3/build.sh` (deploy_agent_v3a, deploy_agent_v3b; `agent_v3_use_psci=false`, `agent_v3_token_binding_opt_out=false`); replay service (`tests/fixtures/replay`) deployed in ANOTHER test project, URL in `agent_v3_replay_url` or `V3H_REPLAY_URL`.

| # | Who | Action | Wait |
|---|---|---|---|
| 9 | human | `agent_g_caa_token_binding_opt_out=false` (default is true), apply; v3a deployed | 4 min after the G apply, 30 min between deploys |
| 10 | script | `RUN_ID=run-N tests/T47.sh s1` (direct control: v3a, no gateway, binding default) then `s2` (G through gateway, expect 401) | |
| 11 | human | `agent_g_caa_token_binding_opt_out=true`, apply | 4 min (and 30 min after the previous deploy) |
| 12 | script | `RUN_ID=run-N tests/T47.sh s3` (expect 200) | |
| 13 | human | `agent_g_caa_token_binding_opt_out=false`, apply | 4 min |
| 14 | script | `RUN_ID=run-N tests/T47.sh s4` (expect 401; writes result) | |
| 15 | script | `RUN_ID=run-N tests/T48.sh bound` (v3a default binding; replay) | |
| 16 | human | `agent_v3_token_binding_opt_out=true`, apply (redeploys v3 agents) | 4 min; 30 min between deploys |
| 17 | script | `RUN_ID=run-N tests/T48.sh optout` (writes result) | |
| 17b | script | T49 (added 2026-11-11): `RUN_ID=run-N tests/T49.sh bound` then `tests/T49.sh optout` (G / G-optout; needs infra/ `v3h_replay_register_on_gateway=true`, set in v3h-block2, applied >= 5 min earlier, and `agent_v3_replay_url` set before G is deployed). The orchestrator does this after T48 | |
| 18 | script | `RUN_ID=run-N tests/T46.sh` (NOT_TESTED with doc evidence; no cloud change) | |

Note: T48 needs `agent_v3_token_binding_opt_out=false` at step 15; set it back to false after step 17 before T44/T45.

## Block 3: perimeter egress (T44) and harness vs platform (T45)

| # | Who | Action | Wait |
|---|---|---|---|
| 19 | human | Runtime project in perimeter spec only (dry-run); v3a deployed, v3b not; no agent ingress identities | |
| 20 | script | `RUN_ID=run-N tests/T44.sh pre` (record artifact sha256) | |
| 21 | human | Enforce the perimeter (no agent ingress rule) | 15 min |
| 22 | human | Deploy v3b from the SAME tarball | 30 min after v3a; 4 min |
| 23 | script | `RUN_ID=run-N tests/T44.sh noingress` | |
| 24 | human | `vpc_sc_agent_ingress_identities=[A,B]` (strings from `terraform output agent_v3`), apply | 15 min |
| 25 | script | `RUN_ID=run-N tests/T44.sh ingress` (writes result) | |
| 26 | human | T45 platform ON, each toggle approved: project deny policy (exception: v3a only), perimeter enforced with the agent ingress rule, v3 agents with `agent_v3_use_psci=true` (SWP allowlist = allowed host), `agent_v3_approved_agents=lzv-v3-a` | 15 min |
| 27 | script | `RUN_ID=run-N tests/T45.sh on` | |
| 28 | human | T45 platform OFF: remove deny policy, project out of perimeter (spec and status), `agent_v3_use_psci=false` (redeploy v3 agents, 30 min apart) | 15 min |
| 29 | script | `RUN_ID=run-N tests/T45.sh off` (writes result) | |
| 30 | human | Restore and verify controls; destroy agents, gateway, SWP, replay service the same day | |

## Block 4: persistence (T43, closes the run next day), back in the per-run project

| # | Who | Action | Wait |
|---|---|---|---|
| 31 | human | `deploy_agent_1=false`, `deploy_agent_2=false`, apply (agents deleted at once); keep the project | |
| 32 | script | `RUN_ID=run-N tests/T43.sh t0` | 15 min |
| 33 | script | `RUN_ID=run-N tests/T43.sh p15` | 24 h after t0 |
| 34 | script | `RUN_ID=run-N tests/T43.sh p24h` | |
| 35 | human | `deploy_agent_3=true`, apply | 5 min |
| 36 | script | `V3H_WAITED_5MIN=yes RUN_ID=run-N tests/T43.sh agent3` (writes result) | |

## T40b (once, dedicated project, own state, e.g. `V3H_RUN=r9` with `RUN_ID=run-1`)

pre (agent 1 deployed, t40b off) -> `tests/T40b.sh pre` -> human sets `t40b_authoritative=true` (do not apply) -> `tests/T40b.sh drift` (plan exit 2) -> human applies, waits 7 min -> `tests/T40b.sh call` (agent 1 model call, expect 403) -> human `deploy_agent_2=true`, apply, 5 min -> `tests/T40b.sh agent2` (writes result). Destroy the project's agents afterwards.

## Additions after Opus review (2026-11-10)

- T48 needs the replay service: build `gcloud builds submit tests/fixtures/replay --tag=<image> --project=<seed>` (human), then infra/ `enable_v3h_replay=true`, `v3h_replay_image`, `v3h_replay_invokers` = v3a/v3b principals (infra/agents output `agent_v3`) + `user:<operator>`; set `agent_v3_replay_url` from output `v3h_replay_url` and re-apply infra/agents. First apply shows whether the org domain policy accepts agent principals as invokers.
- T48 runs with the perimeter in DRY-RUN for the runtime project (the script aborts otherwise): a replay from the seed would be refused by VPC-SC before token binding is checked.

## Needs human approval before run 1 (deviations from the plan text)

1. T45 "platform off" = deny policy removed, runtime project out of perimeter status, `agent_v3_use_psci=false` (agents redeployed from the same tarball). The plan does not define it.
2. T47 step 1 "direct" control uses agent v3a (no gateway, default binding), not agent G.
3. T40/T41 "wait 5 min" is a human export `V3H_WAITED_5MIN=yes`, not a sleep.
4. T44/T45 fixed-argument tool calls in T44 use `MODE=bypass` (T44 tests the platform, not the harness).
5. T48 replay workload is a Cloud Run service in the seed project (not a job in another test project): outside the folder and the perimeter; no extra billing-linked project needed while the quota is pending.

## Plan 3b additions (2026-11-12, orchestrated; scripts never run)

Pre-registration: plans/v3-harness-boundary-tests.md section 3b (commits b4db69f, 9f64dbd, ed713f1, all before the scripts).
Each new script's commit hash goes into the run log before its first run.

**Run 3 (`tests/run-v3h.sh run 3`):** run-2 sequence, except for T44 v2 and T44b:
- block 3: `T44 noingress`, then `T44b noingress`;
- ingress + deny apply, canary;
- `T44b ingress1`;
- wait until 15 min after the ingress apply;
- `T44 ingress` and `T44b ingress15` (both `V3H_WAITED_15MIN=yes`);
- then T45 as before.

**Subset runs 4-9 (`tests/run-v3h.sh subset N`):** no per-run project and no T40-T43.

| Block | Steps |
|---|---|
| 2 (dry-run) | build (adds the T45d tarball `source-v3d.tar.gz`); gateway/SWP/PSC-I/replay; agents a, o, x, G, G-optout; T48b; T50 main; T52 default; agentContextEditor grant (`v3h_t52_grant_context_editor`, approved); T53; T56 calls; T49 (5 min after the replay registry entry); T52 granted (7 min after the grant); grant removed; T56 late (>= 15 min after its last call); T44 pre |
| 3 | enforce; agents b, a_psci, b_psci, a_dep, b_dep, a_dep_psci, b_dep_psci; T44 noingress; T44b noingress; ingress + deny (the dep PSC-I engines get ingress, a_dep_psci is a deny exception); T44b ingress1; +15 min: T44 ingress, T44b ingress15; T45d on; T51; T55; T50 deny; off; deny-removal wait; T45d off |
| end | teardown (agents, perimeter, deny, gateway, SWP, t52 grant); redaction |

**T47r (`tests/run-v3h.sh t47r 1`, one attempt):**
- profile `infra/profiles/v3h-t47r.tfvars` instead of block 2 (IAP V1, no gateway VPC);
- agent G from `source-g-unpinned.tar.gz` (`agent_g_unpinned=true`), default binding;
- 4 min after the deploy, `T47r` runs (one s2 call);
- teardown the same day.

State and log: `scratch/t47r-1/` and `evidence/runs/t47r-1.md`. Manual teardown: `tests/run-v3h.sh teardown 1 --t47r`.

**Versions:** agent G prints google-auth, google-cloud-aiplatform and google-adk versions at import. T47, T47r and T49 read that line from Cloud Logging into a note.

**T47r2 (`tests/run-v3h.sh t47r2 1`, one attempt, conditional):**
- Pre-registration 6fb4740; analysis in `notes/run6-401-analysis.md`.
- Runs only after T49 `bound` (run 3) shows G's token bound: agent_cert, should_request_bound, replay 401. The orchestrator checks this before anything paid, and the script checks it again.
- Same as t47r, but agent G is built from `requirements-run6.txt` (aiplatform 2.6.0, google-genai 2.33.0, google-auth 2.62.0, google-adk 2.13.0) with `agent_g_run6=true`.
- Reading: 401 = client-side cause (H3); 200 = Google-side cause (H1).
- State and log: `scratch/t47r2-1/` and `evidence/runs/t47r2-1.md`. Manual teardown: `tests/run-v3h.sh teardown 1 --t47r2`.
- Needs human approval (paid, about 40 min).
