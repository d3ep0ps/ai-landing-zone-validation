# infra-split: T39 example roots (test only)

Two small roots that read the main state (`../infra/terraform.tfstate`, read only, via `terraform_remote_state`) and use data sources only. `infra/` is not restructured. Human runs `terraform init` and the plans; Claude does not plan or apply.

| Root | Quota project | Reads |
|---|---|---|
| `inside/` | the data project (in the perimeter) | `google_project` and the Cloud Storage service account (`storage.googleapis.com`, a restricted service) of runtime, mcp and data |
| `outside/` | the seed project (outside the perimeter) | `google_project` and the Cloud Storage service account of the outside project, the two folders |

Use: `cd infra-split/inside && cp terraform.tfvars.example terraform.tfvars` (set `quota_project`), `terraform init`, `terraform plan -detailed-exitcode`. Same for `outside/`.

What a full plan proves, and does not: each plan refreshes (reads) every data source, so every API call of the root is made with its own quota project. Exit 0 or 2 (2 only because the new outputs are added to an empty state; no resource changes) with no VPC-SC violation naming either quota project means that each side works when it only touches resources on its own side of the perimeter. It does not prove that a real split of the managed resources behaves the same (managed resources are refreshed through other calls, for example Cloud Build or Cloud Run), and it does not show that a single root could not do it (that is the T22 control). Both plans were read-only checked on 2026-10-27 with the perimeter in dry-run (exit 2, no errors); the enforced result is the test.
