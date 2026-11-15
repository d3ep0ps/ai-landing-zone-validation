# T42 policy gate

Rule: `aiplatform-grant.rego` (package `main`) denies any `resource_changes` entry of type
`google_project_iam_member`, `google_project_iam_binding` or `google_project_iam_policy` whose role starts
with `roles/aiplatform.`. Expected in T42: 0 violations before and after agent deploy, because the
platform's `agentDefaultAccess` grant is made out-of-band and never appears in a plan.

    cd infra-v3h
    terraform plan -var run=r1 -state=state/r1.tfstate -out=state/r1.tfplan
    terraform show -json state/r1.tfplan > state/tfplan.json
    conftest test state/tfplan.json --policy policy

A binding with `members = []` (the T40b toggle) is not flagged: it removes access, it grants nothing.
Before relying on the gate, check it once by hand: add a temporary `google_project_iam_member` for an
`roles/aiplatform.*` role to a scratch plan and confirm conftest fails.

