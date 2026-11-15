# Run order, v1.1 batch B (T20, T21, T22, T24)

Run IDs: `run-4` and `run-5`. Scripts never run `terraform apply`; the human applies. Wait at least 15 minutes after every org-policy or perimeter apply and record the wait in `evidence/runs/RUN_ID.md`.

| Test | Required tfvars | Stages | Waits |
|---|---|---|---|
| T20 | `enable_t07_policy = true`, `enable_dc3_build_bucket = true` (the DC3 key is reused) | single | 15 min after the T07 policy apply. The script waits up to 5 min for the Policy Denied log entry |
| T21 | `enable_dc3_build_bucket = true`, `enable_t07_policy = true` | single | 15 min after the T07 policy apply. Implicit `PROJECT_cloudbuild` bucket must not exist (script checks) |
| T22 | `tooling_quota_project` set to an in-perimeter project (non-empty). Stage `dryrun`: `vpc_sc_enforced = false` with the projects in the dry-run spec. Stage `enforced`: `vpc_sc_enforced = true` | `dryrun`, then `enforced` (same RUN_ID; `enforced` writes the result) | `dryrun`: about 4 min inside the script (violation log lag). `enforced`: 15 min after the perimeter apply, about 2 min inside the script |
| T24 | `enable_dc4_sink = true`, `log_bucket_locked = true` (retention 1 day) | single | Sink and IAM changes take a few minutes: wait 5 min after apply. Script polls up to 15 min (60 s interval) |

Suggested order within a state:

1. State A (T07 policy on, DC3 bucket on): T20, T21.
2. State B (perimeter dry-run, tooling quota project set): T22 `dryrun`.
3. State C (`vpc_sc_enforced = true`, wait 15 min): T22 `enforced`.
4. T24 can run in any state where the sink exists and the logging project is reachable (if the data project is inside the enforced perimeter, run it before state C and note this).

Notes:

- T22 runs `terraform plan -detailed-exitcode -lock=false` read-only with `GOOGLE_BILLING_PROJECT` and `USER_PROJECT_OVERRIDE=true`; exit 0 or 2 counts as success.
- T24 writes an Admin Activity entry that stays in the locked bucket for its retention period; the probe service account is deleted by cleanup.
- T21 and T20 leave the DC3 key ring and key in place (not deletable).
