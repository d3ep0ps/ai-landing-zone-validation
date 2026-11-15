# infra-v3h: per-run project for T40-T43

One Terraform root, one state file per run. Creates `prj-lzv-v3-<run>` under `fldr-ai-prod`
(folder ID read from `../infra/terraform.tfstate`), operator IAM (additive), optional T40b binding,
and agents 1-3 from one tarball. Draft: never planned or applied yet.

## State per run

    cd infra-v3h
    terraform init
    cp terraform.tfvars.example terraform.tfvars   # fill in; tfvars are git-ignored at repo root
    terraform plan  -var run=r1 -state=state/r1.tfstate -out=state/r1.tfplan
    terraform apply -state=state/r1.tfstate state/r1.tfplan

Use `-state=state/<run>.tfstate` on every plan/apply/destroy of that run. `state/` is git-ignored.
Change `run` (r2, r3) for a new project; never reuse a state file across runs.

## Test steps (toggles)

- T40: apply with no toggles, deploy agent 1 with `-var deploy_agent_1=true`, diff IAM, plan again (exit 0 expected).
- T40b: `-var t40b_authoritative=true` (plan exit 2 expected), then apply, call agent 1, then deploy agent 2.
- T41: `-var deploy_agent_2=true`.
- T42: see `policy/README.md`.
- T43: set agents 1/2 to false (apply deletes them), check IAM at +15 min and +24 h, then `deploy_agent_3=true`.
  Keep `-var deploy_agent_N=...` consistent between applies or put them in tfvars.

## Operator roles (additive, `google_project_iam_member`)

`roles/editor`, `roles/iam.serviceAccountUser`, `roles/resourcemanager.projectIamAdmin`. No `roles/aiplatform.*`
(keeps the T42 gate meaningful). Agents get nothing. Override with `operator_roles`.

## Notes

- Source tarball (`agent_source_path`) must exist before `plan` with an agent toggle on; fixture not yet written.
- Billing quota: see plans/v3-harness-boundary-tests.md blocker 1; destroy/unlink each run's project before the next.
- Expected principal set: output `expected_agent_principal_set`.
