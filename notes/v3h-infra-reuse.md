# v3 harness-boundary plan: what infra exists, what to add

Checked 2026-11-10, read-only (Terraform state files, tfvars, live gcloud). Raw output: `scratch/v3h-state/`.
Plan: `plans/v3-harness-boundary-tests.md`.

## 1. Live state today

| Item | Live | Last applied profile (lz-5) says |
|---|---|---|
| Projects (folder tree) | runtime2 (under fldr-ai-prod), data, mcp, outside, + seed | same |
| Perimeter `lzv_ai` | **dry-run** (status 0 projects, spec 3, no ingress/egress) | enforced + operator ingress |
| Folder deny `lzv-v2-deny-agent-predict` (T37) | **absent** | on |
| Project deny (DC1, T18) | absent | off |
| Agents | lzv-probe-a, lzv-probe-b (runtime2), lzv-probe-o (seed), all since 2026-11-04 | deployed |
| Platform grant on runtime2 | `agentDefaultAccess` on the project principalSet: **present** | - |
| SWP, PSC-I, gateway, Cloud Run | none | off |
| Billing-linked projects | **5** (the earlier `Cloud billing quota exceeded` was hit at this size) | - |
| Terraform | `.terraform/` was missing; `terraform init` re-run (local only). Plan fails: ADC is refused `serviceusage.services.use` on PROJECT_6 and `reasoningEngines.get`. ADC needs a fresh login before any plan. | - |

So the T13/T18 windows from 2026-11-04 left the environment off-profile, and three paid agents are still running.

## 2. Plan needs vs what exists

| Plan need | Exists? | Reuse / extend |
|---|---|---|
| Folders `fldr-lz-validation`, `fldr-ai-prod`, europe-west1 | yes | reuse |
| **Fresh runtime project per run** (T40–T43) | no. runtime2 already has the grant, so it cannot show a "first deploy" | **new**: small separate Terraform root per run (project + additive `google_project_iam_member` only), own state file per run. Not in `infra/` state, so the base plan stays unchanged |
| Terraform with additive IAM, plan exit 0 before/after (T40) | pattern exists in base | new root above is exactly the "team's Terraform" under test |
| Authoritative `google_project_iam_binding` toggle (T40b) | no | toggle in the new root (`t40b_authoritative = false`) |
| Rego gate on `tfplan.json` (T42) | no | new `policy/aiplatform-grant.rego` + conftest |
| ADK agent: fixed-arg HTTP tool + GCS copy tool, `HARNESS_GUARD`, `mode=guarded/bypass`, callbacks (T45) | partial: `tests/fixtures/agent` (fetch_url), `agent_c` (proxy fetch) | **new fixture** `tests/fixtures/agent_v3/` built once per run, sha256 recorded; deployed through the same Fabric `geap-agent-runtime` module |
| Deploy into runtime2 (T44, T45, T47, T48) | yes, `infra/agents` | add `deploy_agent_v3{a,b}` toggles using the new source |
| Deploy into fresh project (T40–T43) | no | agents module in the new root (agent 1/2/3 toggles) |
| Perimeter dry-run/enforce, identity ingress for agents (T44) | yes: `vpc_sc_enforced`, `vpc_sc_agent_ingress_identities`, `v4-deploy.sh dryrun/enforce` | reuse |
| IAM deny with per-agent exceptions (T45a) | yes: DC1 (`enable_dc1_deny`, `dc1_approved_agent_principals`) and folder deny (`enable_v2_folder_deny`) | reuse; exception = guarded agent |
| SWP allowlist + PSC-I (T45b) | yes: `swp_enabled`, `enable_v2_psci`, agent C wiring | reuse; change `swp_allowed_host` from `example.com` to a self-owned host |
| Allowed and non-allowed self-owned hosts | no (v1/v2 used example.com) | **new**: two tiny Cloud Run services in the outside project (public, no-auth, static reply) |
| Bucket inside / outside perimeter (T45c) | yes: data project and outside project, CMEK key in outside | reuse; create the two test buckets in the test script, delete same day |
| Agent Gateway, token-binding opt-out (T47, T48) | yes: `enable_v2_gateway`, `enable_v2_gateway_vpc`, IAP V2, agent G, `agent_g_caa_token_binding_opt_out` | reuse; T47 needs a toggle that flips binding with nothing else changed |
| Second workload for token replay (T48) | no | **new**: Cloud Run job in the outside project, token passed in memory only (design needs care: no token on disk) |
| Budget alert | yes (`test-budget` USD 50, Vertex budget USD 10) | reuse |

## 3. Blockers and decisions

1. **Billing quota.** 5 linked projects, and the quota was exceeded at this size before. A fresh project per run will fail unless one project is unlinked first (mcp is only used by T21/T25 and is the candidate) or a quota increase is granted. Each run's project must also be unlinked/deleted before the next.
2. **Running agents.** A, B, O have run since 2026-11-04. Rule: paid resources die the same day. Destroy them (or confirm they are wanted) before v3.
3. **Off-profile state.** Decide the v3 starting point: return to lz-5 (enforced, folder deny on) and toggle per test, or start from dry-run.
4. **ADC login.** Run `! gcloud auth application-default login` before any plan.

## 4. Extension, smallest change first

1. `infra-v3h/` new root: per-run project in `fldr-ai-prod` (`prj-lzv-v3-rN`), additive IAM for the operator only, agent 1/2/3 toggles, T40b toggle. Reads base outputs through `terraform_remote_state` (as `infra/agents` does). State `infra-v3h/state/runN.tfstate`.
2. `infra/v3h-targets.tf`: two Cloud Run hosts in the outside project (toggle `enable_v3h_targets`), outputs URLs; `swp_allowed_host` set from it.
3. `tests/fixtures/agent_v3/`: ADK agent with guard callbacks and bypass modes; `build.sh` prints sha256.
4. `infra/agents`: `deploy_agent_v3a/b` (runtime2, same tarball) for T44/T45.
5. T47: separate toggle for the binding flip on the gateway agent; T48 replay job (design review before code).
6. `policy/` Rego rule for T42.
7. Tests T40–T48 by test-script-writer, expected text in each header.
