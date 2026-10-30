# Phase 2 review: infra/ draft (Opus, 2026-10-23)

Draft by infra-writer. `terraform fmt`, `init -backend=false`, `validate`: success. No plan or apply run.

## Scope check

- Org-level writes: only (a) `fldr-lz-validation` created with parent = org, and (b) the access policy, whose parent must be the org (API requirement) but whose scope is the folder. No org-level IAM, org policies, sinks or perimeters. Accepted.
- All 7 org policies (10 with toggles) are on `fldr-lz-validation` or `fldr-ai-prod`. No project-level or org-level policies.
- Perimeter: dry-run spec only while `vpc_sc_enforced = false`. `prj-lzv-outside` is not in the perimeter.
- Log bucket: retention 1 day, `locked = var.log_bucket_locked` (default false). No sink routes logs into it.
- No service account keys, no secrets, placeholders only in `terraform.tfvars.example`.

## Findings to act on before or during apply

1. **Quota project.** Human decided: the seed project; `quota_project` is now required (no default). It it needs `orgpolicy`, `accesscontextmanager` and `cloudresourcemanager` APIs enabled (human, state change in the seed project).
2. **Cross-test interference (Phase 3).** `run.allowedBinaryAuthorizationPolicies = default` is on the whole folder, so T02 and T03 deploys without `--binary-authorization=default` may be denied by T17's policy instead of their own. T02/T03 scripts must pass `--binary-authorization=default` and attribute denials by constraint name.
3. **T04 model list.** `allowed_models` defaults to one model chosen by the subagent. Human decided: no default; choose at apply time and record the allowed and the denied model before run 1.
4. **Project deletion.** Fabric project module default `deletion_policy = "DELETE"`: `terraform destroy` deletes projects. Wanted for Phase 8 teardown; a mistaken destroy is also immediate (30-day soft delete applies).
5. **BLOCKER: scoped policy needs an org-level access policy.** Verified by Opus from https://docs.cloud.google.com/access-context-manager/docs/scoped-policies: "If an organization-level access policy doesn't exist for your organization, ... scoped policies that you create at the folder or project-level will not operate." Read-only check 2026-10-23 (`gcloud access-context-manager policies list --organization=ORG_ID`): the org has 0 access policies. Human decided (2026-10-23): add an EMPTY org-level access policy; the perimeter stays in the folder-scoped policy. Applied in infra/vpc-sc.tf.
   Child folder: docs imply but do not state that a folder-scoped policy can secure projects in nested folders (medium). If apply rejects `prj-lzv-runtime`, move it under `fldr-lz-validation` and set T04 on the project.
6. **Org policy value format**: docs write `internal` / `default` plain; `is:` prefix is supported. Keep plain; an API rejection is a finding (medium).
7. **Locked bucket and teardown**: an empty locked bucket can be deleted (enters DELETE_REQUESTED for 7 days); minimum retention 1 day. No sink routes logs into it, so it stays empty. Effect on project deletion is not documented (low).

## Not yet planned (later phases)

- T14 needs an operator ingress rule before enforcement (placeholder comment in vpc-sc.tf).
- T11 agent runtime is not in this apply; it is deployed in Phase 4 from `modules/geap-agent-runtime`.
- CMEK key for T07 positive control and T10 workaround: not in this apply (optional).
