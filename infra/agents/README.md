# infra/agents: T11/T14 probe agents (separate root, local state)

- Reads project id/number from `../terraform.tfstate` (apply `infra/` first). Human runs all applies.
- Build the source: `tests/fixtures/agent/build.sh` (writes `infra/agents/build/source.tar.gz`, git-ignored).
- Stage 1: `terraform apply -var deploy_agent_a=true` (needs `model`, `quota_project` in terraform.tfvars).
- Stage 3b (RUN-ORDER.md): the operator ingress rule (storage + aiplatform) must exist first, then `-var deploy_agent_a=true -var deploy_agent_b=true`.
- Stage 4: destroy with both bools false (or `terraform destroy`). Deletion protection is off.
- Cost: small, per-use Agent Runtime plus model calls; destroy the same day.
- No IAM roles are granted to the agent principals (`service_account_config.roles = []`). T12 only reads IAM; it grants nothing.
- Fixed after first deploy failure: `class_methods` declared, entrypoint object `app` (AdkApp). Unverified, deploy may need hidden storage/build.
- v2 agent C (T33, T34): `tests/fixtures/agent_c/build.sh` writes `build/source-c.tar.gz`; `-var deploy_agent_c=true` deploys it with a PSC interface (needs infra/ with `swp_enabled` and `enable_v2_psci`; reads `v2_psci_attachment_id` and `swp_proxy_url` from the infra/ state). Deploy after enforcement and the agent ingress rule, 30 minutes after the previous deploy. If the deploy rejects the attachment path, retry with `-var agent_c_short_attachment_name=true`.
