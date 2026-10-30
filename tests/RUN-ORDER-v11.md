# v1.1 run order (overview)

Run IDs: `run-4` (first v1.1 run) and `run-5` (repeat). Every Terraform apply is done by the human; scripts never apply. Wait 15 minutes after each org-policy or perimeter change. Per-test details: [part a](RUN-ORDER-v11-a.md) (T19, T18), [part b](RUN-ORDER-v11-b.md) (T20, T21, T22, T24), [part c](RUN-ORDER-v11-c.md) (T25, T23, T16).

Order is chosen so toggles do not overlap in ways that change another test's outcome.

| Stage | Toggles applied before (infra unless noted) | Tests | Cost |
|---|---|---|---|
| 1 | `enable_t07_policy=true`, `enable_dc3_build_bucket=true` | T20, T21 | cents |
| 2 | `enable_t07_policy=false`; `enable_dc4_sink=true` | T24 | free |
| 3 | `enable_t25_binauthz=true` (keep `enable_dc3_build_bucket=true`, T25 builds through it). T17's positive control is refused while this is on; do not run T17 here | T25 | cents |
| 4 | No apply (changed 2026-10-25 during run-4): `enable_t25_binauthz` stays on until the final reset, because KMS key rings cannot be deleted and re-enabling T25 for run-5 would fail on the existing key ring; no other v1.1 test deploys Cloud Run in the mcp project. Agents: none deployed | T19 `before` | free |
| 5 | infra/agents: `deploy_agent_a=true` | T19 `after` | low |
| 6 | infra/agents: `deploy_agent_b=true` | T18 `pre` (prints the principal strings) | low |
| 7 | `enable_dc1_deny=true`, `dc1_approved_agent_principals=[A]`; wait 10 min | T18 `post` | low |
| 8 | `enable_dc1_deny=false`; agents B destroyed; runtime project removed from the perimeter dry-run spec (as T14R) | T23 `pre` | low |
| 9 | `tooling_quota_project=<in-perimeter project>`, set `quota_project` / `GOOGLE_BILLING_PROJECT` per infra/README.md | T22 `dryrun` | free |
| 10 | `vpc_sc_enforced=true`, `vpc_sc_agent_ingress_identities=[A]`, deploy agent B, then `[A, B]`; wait 15 min | T22 `enforced`, T23 `post` | low |
| 11 | `swp_enabled=true` (same day: build, test, destroy) | T16; then `swp_enabled=false` apply and check the gateway is gone | ~USD 1.25/h |
| 12 | Reset (after run-5): all v1.1 toggles off (T25 off last; check the mcp Binary Authorization policy is back to ALWAYS_ALLOW), agents destroyed, perimeter back to dry-run base; drift check | — | — |

Notes:
- Stage 8 (dry-run spec without the runtime project) and stages 9–10 (runtime in the perimeter) follow the T14R pattern; see part c.
- Cloud Run job deletion in T16 may need a terminal; if so it is a human step (the `--quiet` exception covers only Cloud Run services via `cleanup_run_service`).
- KMS key rings and keys created in stages 1 and 3 cannot be deleted; they go with their projects at teardown.
