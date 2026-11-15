# Run order (fixed in Phase 3, 2026-10-23)

This replaces the order list in EXECUTION-PLAN.md Phase 4, because several tests share one folder and some fixtures must exist before a policy is switched on. Terraform applies are done by the human; scripts never run `terraform apply`.

Before each stage: wait at least 15 minutes after the last org-policy or perimeter apply (docs: up to 15 min to take effect) and record the wait in `evidence/runs/RUN_ID.md`.

## Stage 1: base state (as applied in Phase 2)

State: `enable_t05_policy = enable_t06_policy = enable_t07_policy = false`, `vpc_sc_enforced = false` (perimeter dry-run), log bucket locked.

| Step | Test | Why here |
|---|---|---|
| 1 | T01, T02, T03, T17 | Policies always on. Cloud Run deploys comply with all other folder policies. |
| 2 | T04 | Needs `T04_DENIED_MODEL` set by the human and recorded in the run file before the run. |
| 3 | T08 | T07 (CMEK) is off, so only the location policy can deny the `us-central1` bucket. |
| 4 | T09 | Creates a plain EU bucket, which T07 would block. |
| 5 | T06 `before` | Effective value before the folder policy exists. |
| 6 | T13 `setup`, T13 `dryrun` | Creates the perimeter and outside buckets while T07 is off; dry-run control (requests succeed, violations logged with `dryRun=true`). |
| 7 | T15 | Lock already applied in Phase 2. |
| 8 | human: apply `infra/agents` with `deploy_agent_a = true` | Paid (small). |
| 9 | T11, T12, T14 `a` | T14 agent A is deployed before the perimeter is enforced. |

## Stage 2: policy toggles on

Human apply: `enable_t05_policy = enable_t06_policy = enable_t07_policy = true`. Wait 15 min.

| Step | Test |
|---|---|
| 1 | T05 |
| 2 | T06 `after` (writes the result) |
| 3 | T07 |
| 4 | T10 (T07 is its precondition) |

## Stage 3a: perimeter enforced, no ingress rule

Human apply: `vpc_sc_enforced = true`. Wait. From now on the operator cannot reach storage or Vertex AI in the perimeter projects.

| Step | Test |
|---|---|
| 1 | T13 `outside-read` (expect `NO_MATCHING_ACCESS_LEVEL`) |

## Stage 3b: perimeter enforced, operator ingress rule

Human apply: add the operator ingress rule (storage and aiplatform). Wait.

| Step | Test |
|---|---|
| 1 | T13 `copy` (expect `RESOURCES?_NOT_IN_SAME_SERVICE_PERIMETER`; writes the result; cleans up both buckets) |
| 2 | human: apply `infra/agents` with `deploy_agent_b = true` |
| 3 | T14 `b` (writes the result) |

## Stage 4: back to base

Human: destroy agents (`deploy_agent_a = deploy_agent_b = false`), remove the ingress rule, `vpc_sc_enforced = false`, toggles off. Run 2 starts again from Stage 1 on a different day.

## Known limitation

T14 agent A is deployed while the runtime project is already in the perimeter's dry-run spec. Docs say an agent is secured only if the project is in a perimeter before deploy; we assume dry-run membership does not count. If agent A's fetch fails, that assumption is wrong: record it as a finding.

## T14R re-test (added 2026-10-25, Phase 6 H1, human approved)

Separate sitting from runs 1 and 2, `RUN_ID=run-3`. Start and end at base state.

| Step | Who | Action |
|---|---|---|
| 0 | Opus (gcloud, approved) | Remove the runtime project from the lzv_ai dry-run spec (`perimeters dry-run update --remove-resources`); describe shows it in neither spec nor status |
| 1 | apply | `infra/agents` with `deploy_agent_a = true` only |
| 2 | test | `T14R.sh pre` |
| 3 | apply + gcloud | Stage 3a plan (re-adds the project to the spec and enforces the status); operator ingress via gcloud as in run 2; wait 15 min |
| 4 | test | `T14R.sh post` (writes the result) |
| 5 | Stage 4 | destroy agent A, reset the perimeter with gcloud, `vpc_sc_enforced`/ingress back to false, drift check |
