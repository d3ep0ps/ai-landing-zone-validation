# AI Landing Zone Reference Validation

This repository produces reproducible evidence that the AI landing zone controls work in a reference GCP organization. The full plan is in `EXECUTION-PLAN.md`; current state is in `PROGRESS.md`.

## Start of every session

1. Read `PROGRESS.md` to find the current phase and next step.
2. Read only the `EXECUTION-PLAN.md` section for that phase (plus the appendices it names).
3. Do not read the whole repository or the whole Fabric checkout.

## Working rules

- One phase per session. Finish by updating `PROGRESS.md`, committing, and summarising in under 15 lines.
- Never paste raw command output into the conversation. Write it to `evidence/` or `scratch/` and show a short `jq` or `tail -n 20` summary.
- Delegate verbose work to the subagents in `.claude/agents/`. Ask them for at most 20 lines back.
- Use `notes/doc-verification.md` as the source for commands, flags and error signatures. Do not re-fetch documentation that is already recorded there.
- Use the Sonnet/Haiku subagents for mechanical work; keep Opus (main session) for decisions and reviews.

## Safety rules

- Before any command that changes cloud state, verify: active gcloud configuration is `lz-validation`, the account and organization match `PROGRESS.md`. If not, stop.
- Apply policies to the test folder `fldr-lz-validation` only, unless the test spec says otherwise.
- Never use `--quiet` on create or delete commands. Never `git push`.
  - Exception (human-approved 2026-10-23): `--quiet` is allowed only on the cleanup delete of a Cloud Run service the same test script created, by exact name, via `cleanup_run_service` in `tests/lib.sh` (`gcloud run services delete` cannot be confirmed without a terminal).
- Never keep service account keys. Never write tokens or secrets to files.
- Paid resources are created only in their phase and destroyed the same day.
- If observed behaviour differs from the expected result, record it as a finding. Never change an expected result after a run.

## Evidence standard

Every test writes `evidence/TNN/command.txt`, `output.txt` and `result.json` (schema in `EXECUTION-PLAN.md` section 4). Expected results are written in the script before it runs. Verdicts: PASS, FAIL, NOT_TESTED, INCONCLUSIVE. Tiers: Enforced, Configured, Documented.

## Wording

In any report text, do not use "production-grade", "audit-ready" or "compliant". State what was tested, the result, and the limitation.
