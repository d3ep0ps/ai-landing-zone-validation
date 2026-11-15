# Cost-effective AI landing zone profile

Brings up the reference AI landing zone from the existing `infra/` stack with every control that costs nothing (or cents) and nothing that bills by the hour. Not included: agents (Agent Engine), Secure Web Proxy (T16), Agent Gateway (T30-T32), PSC interface (T33-T34), org-scope controls (T36, T38).

| Stage | File | Adds | Cost |
|---|---|---|---|
| 0 | (current base state) | folders, 4 projects, dry-run perimeter, locked log bucket, `vertexai.allowedModels` and other folder policies | 0 |
| 1 | `lz-1-base.tfvars` | Model Armor API + template (T28), folder Admin Activity sink to the locked bucket (DC4) | 0 |
| 2 | `lz-2-controls.tfvars` | T05/T06/T07 folder policies, Model Armor floors enforcing at folder (T27) and runtime project with Vertex AI (T29), folder IAM deny on agent predict (T37) | 0 |
| 3 (optional) | `lz-3-cmek.tfvars` | CMEK build bucket (DC3), Binary Authorization (T25), reusing the existing keys | ~USD 0.15/month (2 key versions) |
| 4 | `lz-4-enforce.tfvars` | Perimeter enforced, operator ingress, storage egress for the seed quota project | 0 |
| 5 (v3) | `lz-5-reference.tfvars` | Six extra boolean folder policies, Vertex AI budgets per project (alert only), folders fldr-ai-sandbox/dev/staging with optional `vertexai.allowedModels`, CMEK key-project policy, Model Armor in the perimeter, VPC `lzv-net-vpc` with restricted VIP and egress deny-all (NET-03 partial: no proxy, no NAT) (`infra/v3-lz.tf`) | about USD 0.20/month (private DNS zone) |

Files are cumulative: pass `terraform.tfvars` plus the highest stage only. Wait 15 minutes after each apply (org policy / perimeter propagation).

```
cd infra
terraform plan -var-file=terraform.tfvars -var-file=profiles/lz-1-base.tfvars -out=plan-lz-1.tfplan
terraform apply plan-lz-1.tfplan        # human only
```

Rules (CLAUDE.md): check `lz-validation` config and ADC identity before each plan; the human applies; one stage per apply.

Notes
- Stage 2: T07 blocks non-CMEK buckets in the folder. Model Armor floors cannot be deleted; roll back with `v2_ma_floor_enforce.<level>=false`, apply, then turn the floor toggles off (infra/README.md "v2 Model Armor notes").
- Stage 3: restore and enable version 1 of both keys first (infra/README.md "v2 P2", path A, until 2026-11-26). Expect two applies: the first fails on the Binary Authorization policy with "Provider produced inconsistent final plan" (attestor ID unknown at plan time; observed 2026-11-03); re-plan and apply again (1 add).
- Stage 4: set `operator_email` and `vpc_sc_pipeline_egress` in `terraform.tfvars` (template in the file). Apply once with `-var=vpc_sc_enforced=false`, check dry-run violations, then enforce with `-target=module.vpc_sc`. Without the egress rule Terraform loses access to its own stack (Finding 9, T22).
- Stage 5 (v3): set `v3_env_allowed_models` and `v3_cmek_key_projects` in `terraform.tfvars`; enable `billingbudgets.googleapis.com` on the quota project first. The perimeter gains `modelarmor.googleapis.com` and the operator ingress rule then covers all restricted services. Budgets alert only; they do not cap spend.
- Teardown: reverse order (4 → 0); see `tests/RUN-ORDER-run6.md` stages 1-5 and 2-8 for the reset steps.
