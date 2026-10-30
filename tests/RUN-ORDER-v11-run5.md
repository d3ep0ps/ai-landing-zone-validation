# v1.1 run-5 order (repeat of run-4, fewer agent deploys)

Decided 2026-10-26 by the human: run-5 uses an order with two agent deploys instead of four (run-4 deployed agents four times and destroyed them twice; the runtime project was suspended a few hours later; no cause is known or claimed). Expected results are unchanged: every test script's `header` text is identical to the first v1.1 script commit (2a40b00), checked 2026-10-26. Run ID `run-5` for every test; retries use `run-5-rN`.

Rules as in [RUN-ORDER-v11.md](RUN-ORDER-v11.md): the human applies every Terraform plan; scripts never apply; wait 15 minutes after each org-policy or perimeter change and 10 minutes after the deny policy. Before each batch: active gcloud configuration `lz-validation`, account and organization as in PROGRESS.md, and both logins fresh (they expire after about an hour).

## Deviations from run-4 (record them in `evidence/runs/run-5.md`)

1. T18 runs with the perimeter enforced (agent ingress for A and B, operator ingress), on the same two agents as T23. In run-4 it ran with the perimeter in dry-run, on agents deployed for T19 and T18.
2. Agent A for T19 is deployed while the runtime project is in neither the dry-run spec nor the status (in run-4 it was in the dry-run spec). The same agent A then serves T23 `pre`.
3. Fixes since run-4 that apply here: T22 VPC-SC signature (8430c2c), T25 build-object cleanup (cb0197b), SWP outputs set by a targeted plan (b138546), `redact.py` project-ID prefix match.

## Days

Paid resources are created and destroyed on the same day. Agents exist only on day 2.

- Day 1: stages 0–2 (no agents after stage 0a).
- Day 2: stages 3–9 (both agent deploys, T16, reset).

## Stages

| Stage | Who / what | Tests (`RUN_ID=run-5`) |
|---|---|---|
| 0a | infra/agents: `deploy_agent_a=false`, `deploy_agent_b=false`; apply (destroys both run-4 agents). | — |
| 0b | infra, targeted (`-target=module.vpc_sc -var quota_project=<data>`, full plans fail while enforced): `vpc_sc_enforced=false`, `vpc_sc_agent_ingress_identities=[]`. Then a full plan to check no other drift; finish the SWP subnet/VPC destroy if still pending. | — |
| 1 | `enable_t07_policy=true`; wait 15 min (the perimeter is in dry-run, so full plans work again). | T20, T21 |
| 2 | `enable_t07_policy=false`; wait 15 min. T25 is already on (stays on until stage 9). After T25: human deletes the Artifact Registry repository in their own terminal (the script prints the `HUMAN CLEANUP:` command). | T24, T25 |
| 3 | gcloud, human approved: remove the runtime project from the dry-run spec (as run-4 stage 8 / T14R). It must come after the last full infra apply before stage 5, or Terraform puts the project back. Wait 15 min. Guard: no agents. | T19 `before` |
| 4 | infra/agents: `deploy_agent_a=true`. | T19 `after`, then T23 `pre` |
| 5 | infra: apply restores the dry-run spec to the 3 projects (runtime back in); `tooling_quota_project` stays the data project. Wait 15 min. | T22 `dryrun` |
| 6a | infra: `vpc_sc_enforced=true`, `vpc_sc_agent_ingress_identities=[A]` (A principal from infra/agents output). Wait 15 min. | — |
| 6b | infra/agents: `deploy_agent_b=true` (agent B deployed inside the enforced perimeter). | — |
| 6c | infra, targeted at `module.vpc_sc` with `-var quota_project=<data>`: `vpc_sc_agent_ingress_identities=[A, B]`. Wait 15 min. | T22 `enforced`, T23 `post` |
| 7 | T18 `pre` first (deny off). Then infra, targeted (`-target=google_iam_deny_policy.dc1_agents_predict -var quota_project=<data>`): `enable_dc1_deny=true`, `dc1_approved_agent_principals=[A]` (the new A principal, printed by T18 `pre`). Wait 10 min after the policy createTime. | T18 `pre`, T18 `post` |
| 8 | infra, targeted at the SWP blocks: `swp_enabled=true` (gateway billed per hour). After the test: human deletes the three jobs in their own terminal, then applies the targeted `swp_enabled=false` plan the same day. The job subnet may stay held by a Cloud Run serverless address for a while; re-plan later. | T16 |
| 9 | Reset (stage 12 of RUN-ORDER-v11): `enable_dc1_deny=false`; agents destroyed; perimeter back to dry-run, ingress removed; `enable_dc3_build_bucket=false`, `enable_dc4_sink=false`, `tooling_quota_project=null`; `enable_t25_binauthz=false` last, then check the mcp Binary Authorization policy is back to ALWAYS_ALLOW; untargeted plan shows no drift. KMS key rings stay (cannot be deleted). | — |

## Pacing (suspension risk; not a known cause)

- One agent deploy at a time; at least 30 minutes between the two deploys (stage 4 and stage 6b fall about an hour apart anyway).
- No rapid retries of a failed deploy or model call: stop, read the error, then decide.
- If any runtime call returns `CONSUMER_SUSPENDED`: stop the run, apply nothing, record it, and ask the human.

## Human steps in run-5

Applies at stages 0a, 0b, 1, 2, 4, 5, 6a, 6b, 6c, 7, 8 (on and off), 9; the gcloud spec change at stage 3; the AR repository delete after T25; the three Cloud Run job deletes after T16; logins when they expire. Teardown later: remove the organization-level `roles/iam.denyAdmin` grant.
