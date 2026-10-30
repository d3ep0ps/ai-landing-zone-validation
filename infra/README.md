# infra

Terraform for the reference environment, using pinned Cloud Foundation Fabric modules. Drafted in Phase 2. Claude never plans or applies; the human does.

## Requirements

- Terraform >= 1.12.2; providers pinned to Fabric's `default-versions.tf` (google, google-beta >= 8.6.0, < 9.0.0).
- `vendor/fabric` checked out at commit be0d4b1 (Fabric v59.2.0). `vendor/` is git-ignored; modules are referenced as `../vendor/fabric/modules/...`.
- Local state (git-ignored). No service account keys, no secrets.
- Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in `ORG_ID`, `BILLING_ACCOUNT`, `PREFIX`.

## Human decisions flagged

- Org-level resources: the folder `fldr-lz-validation`, an EMPTY org-level access policy (no perimeters or access levels; required for scoped policies to operate), and the access policy scoped to `fldr-lz-validation` (parent = org, API requirement). Creating the access policies needs `accesscontextmanager.policies.create` at the org. No org-level IAM or org policies.
- `log_bucket_locked = true` is irreversible and a locked bucket with data cannot be removed before retention elapses.
- Folder creation under the org and project billing association need org-level roles for the operator.
- `quota_project`: the seed project (decided). Enable `orgpolicy`, `accesscontextmanager` and `cloudresourcemanager` APIs on it before the first apply.
- `allowed_models`: no default; choose one current model from Model Garden at apply time and record it, plus the model T04 will call and expect to be denied.

## Apply order

1. Base apply: all toggles false, `vpc_sc_enforced=false` (dry-run), `log_bucket_locked=false`. Save the plan summary to `evidence/environment/plan-summary.txt`.
2. Verify: folders/projects tree, effective policies, perimeter exists in dry-run and `prj-lzv-outside` is not in it, log bucket retention is 1 day and `locked` is false. Wait for org-policy propagation and record the time.
3. Lock the bucket: set `log_bucket_locked=true`, apply separately.
4. Enable `enable_t05_policy`, `enable_t06_policy`, `enable_t07_policy` in the order Phase 3 fixes for T07-T10 (T07 first would block T09's test bucket unless it is created first). Apply each toggle separately so an unknown constraint (T05) fails alone.
5. Enforce the perimeter: add the operator ingress rule (see `vpc-sc.tf`, needed by T13/T14), then set `vpc_sc_enforced=true`. Enforcement also affects Terraform's own API calls to restricted services in the perimeter projects.

Do not run `terraform destroy` on the log bucket after locking without reading `environment.md`.

## v1.1 (drafted, not applied)

Every v1.1 item is behind a toggle that defaults to off, so the base apply creates nothing new that changes test outcomes. Add the keys from `terraform.tfvars.example` ("v1.1" block) to your own `terraform.tfvars`; this repo never edits it. No new projects (billing limit about 5 linked projects).

**New prefix required.** v1 projects were deleted and their IDs are pending deletion for 30 days. Set a new `prefix` in `terraform.tfvars` before the first apply (project IDs derive from it). Terraform state is empty.

| File | Toggle / variable | Test | Creates |
|---|---|---|---|
| `v11-dc1.tf` | `enable_dc1_deny`, `dc1_approved_agent_principals` | T18 | Deny policy on the runtime project: `aiplatform.googleapis.com/endpoints.predict` denied to the project agent principalSet, exceptions = approved `principal://` strings |
| `v11-dc2.tf` | `tooling_quota_project`, `vpc_sc_agent_ingress_identities` | T22, T23 | Ingress rule `agents` (also in the dry-run spec) from those identities to `aiplatform.googleapis.com` on the runtime project; `vpc-sc.tf` merges it with the operator rule |
| `v11-dc3.tf` | `enable_dc3_build_bucket`, `dc3_build_service_accounts` | T21 | Key ring + key and a CMEK bucket (europe-west1, runtime project), Cloud Storage agent granted encrypter/decrypter, build SAs granted `objectAdmin` on the bucket |
| `v11-dc4.tf` | `enable_dc4_sink` | T24 | Folder sink (include_children) of Admin Activity logs to the locked log bucket; writer identity gets `logging.bucketWriter` and `logging.logWriter` on the logging project |
| `v11-t25.tf` | `enable_t25_binauthz` | T25 | In the mcp project: Binary Authorization policy, attestor, note, KMS signing key (EC_SIGN_P256_SHA256), 2 APIs |

Outputs: `dc1_deny_policy_name`, `tooling_quota_project`, `dc3_build_bucket`, `dc4_sink_writer_identity`, `t25_attestor_name`, `t25_note_name`, `t25_key_version_id`.

Operator roles needed (not granted by Terraform): `roles/iam.denyAdmin` at org or project (DC1); `roles/logging.configWriter` on the folder and permission to set IAM on the logging project (DC4); for T25 attestations `roles/containeranalysis.notes.attacher`, `roles/containeranalysis.occurrences.editor` and `roles/cloudkms.signerVerifier` (the last is granted to `operator_email` when set).

Irreversible or lingering items:
- KMS key rings and keys (DC3, T25) cannot be deleted; `terraform destroy` only schedules key version destruction. The ring and key stay in the project after destroy, and their names stay taken in that project.
- DC4 writes into the locked bucket: entries cannot be deleted before retention lapses and the logging project stays (accepted in DC4).
- T25 default-admission rule: while enabled, the mcp project requires an attestation for any Cloud Run deploy with `--binary-authorization=default` (including T17's positive control). Set the toggle back to false and apply to restore the default policy (the provider resets it to ALWAYS_ALLOW on destroy; check with `gcloud container binauthz policy export`).

DC2 quota project (T22). Terraform: the providers use `billing_project = var.quota_project`. To use an in-perimeter project, set `quota_project` in `terraform.tfvars` to its ID once that project exists (the provider cannot reference a resource created in the same run), or use the env vars `GOOGLE_BILLING_PROJECT` and `GOOGLE_USER_PROJECT_OVERRIDE=true` after removing the explicit setting. gcloud: add `--billing-project=PROJECT_ID`. `tooling_quota_project` only records the choice in an output.
Rollout order for DC2: dry-run with a recorded violation review, then enforce; deploy agents only after enforcement or add their identities to `vpc_sc_agent_ingress_identities` first.

Validated with `terraform fmt` and `terraform validate` only; nothing planned or applied.

## v2 (run-6, drafted, not applied)

All v2 items are toggles that default to off. Files: `v2-p2-kms.tf`, `v2-model-armor.tf`, `v2-psci.tf` (plus edits in `v11-swp.tf`), `v2-org.tf`, `vpc-sc.tf` (T39b), `variables.tf` (all v2 variables), `infra/agents` (agent C), `infra-split/` (T39). Validated with `terraform fmt` and `terraform validate`; a plan with all v2 toggles on (4 imports, 38 adds, 2 changes, no destroys) was read-only checked on 2026-10-27, nothing applied.

| Toggle / variable | Test | Scope | Creates |
|---|---|---|---|
| `p2_import_existing_kms`, `p2_create_key_versions` | P2 (T21, T25) | project | import of the 2 key rings + 2 keys; optionally a new version per key |
| `enable_v2_model_armor` | T28 | project | `modelarmor.googleapis.com` in runtime; template `lzv-ma-pi` (europe-west1, pi_and_jailbreak MEDIUM_AND_ABOVE) |
| `enable_v2_ma_folder_floor` | T27 | folder | floor setting on `fldr-lz-validation` (pi_and_jailbreak MEDIUM_AND_ABOVE, enforcement on) |
| `enable_v2_ma_vertex` | T29 | project | project floor setting on runtime with `AI_PLATFORM` / `inspect_and_block`; Vertex AI service agent identity; `roles/modelarmor.user` for it |
| `enable_v2_ma_org_floor` | T38 | **organization** | org floor setting; `modelarmor.googleapis.com` in the data project (the T38 test project) |
| `v2_ma_floor_enforce` | A | per level (`folder`, `project`, `org`) | `enableFloorSettingEnforcement`; set the level false and apply before switching its floor toggle off; T38 needs `folder = false` |
| `enable_v2_psci` (needs `swp_enabled`) | T33, T34 | project | subnet `lzv-swp-psci` 10.77.4.0/28, attachment `lzv-psci` (ACCEPT_AUTOMATIC), attachment CIDR added to the two firewall allows (the 65000 deny-all has no source range and covers it), `roles/compute.networkAdmin` for the Vertex AI service agent |
| `deploy_agent_c` (`infra/agents`) | T33, T34 | project | agent C with `psc_interface_config.network_attachment`, env `PROXY_SERVER_URL` |
| `t36_mode` = dryrun / enforce, `t36_exception_project` | T36 | **organization** | custom constraint `custom.lzvOrgTestBucketLabel` (Bucket, CREATE, ALLOW, label `lzv-org-test`), org policy (dry_run_spec or spec), project policy `enforce = FALSE` on the exception project (outside by default: outside the perimeter, only T13 destination buckets; data is the alternative) |
| `enable_v2_folder_deny` | T37 | folder | deny policy `lzv-v2-deny-agent-predict` on the folder: `principalSet://agents.global.org-ORG_ID.system.id.goog/*` denied `aiplatform.googleapis.com/endpoints.predict`, exception `dc1_approved_agent_principals` (set `enable_dc1_deny=false` in the same apply) |
| `vpc_sc_pipeline_egress` | T39b | perimeter | egress policy `pipeline` (identity -> `projects/QUOTA_PROJECT_NUMBER`, `serviceusage.googleapis.com`), in the dry-run spec always and in the status when `vpc_sc_enforced` |

**Org scope (flagged):** `enable_v2_ma_org_floor`, `t36_mode` != off. The pre-existing org-level VPC-SC access policy is unchanged. Apply these one at a time, each alone, with the rollback below ready.

Operator roles (not granted by Terraform): `roles/modelarmor.admin` (runtime), `roles/modelarmor.floorSettingsAdmin` on the folder / runtime project / organization (T27 / T29 / T38), `roles/modelarmor.user` for callers of `sanitizeUserPrompt` and the Vertex service agent (granted by Terraform to the agent), `roles/orgpolicy.policyAdmin` on the organization (T36), `roles/iam.denyAdmin` on the folder (T37). `modelarmor.googleapis.com` must be enabled on the quota project (seed) by hand, because the providers bill their calls to it.

### v2 P2: existing key rings (`lzv-build-keyring`, `lzv-attestor-key`)

Read-only check on 2026-10-27: each key has one version, number 1, `DESTROY_SCHEDULED`, destroy time 2026-11-26. The key itself was never deleted (cannot be). A plan with the import on shows, per key: 1 import for the ring, 1 import + update in place for the key. The key update only adds `rotation_period` (DC3 key; the API had lost it), `skip_initial_version_creation = false` (a provider-only field) and the Terraform label. No replacement, no destroy. The IAM bindings on the keys are created new.

Path A (preferred, valid until 2026-11-26; the human runs these, they change cloud state):
```
gcloud kms keys versions restore 1 --project=RUNTIME_PROJECT --location=europe-west1 --keyring=lzv-build-keyring --key=lzv-build-key
gcloud kms keys versions enable  1 --project=RUNTIME_PROJECT --location=europe-west1 --keyring=lzv-build-keyring --key=lzv-build-key
gcloud kms keys versions restore 1 --project=MCP_PROJECT --location=europe-west1 --keyring=lzv-binauthz-keyring --key=lzv-attestor-key
gcloud kms keys versions enable  1 --project=MCP_PROJECT --location=europe-west1 --keyring=lzv-binauthz-keyring --key=lzv-attestor-key
```
Then `p2_import_existing_kms=true` with `enable_dc3_build_bucket=true` / `enable_t25_binauthz=true`; `p2_create_key_versions` stays false (T25 keeps reading version 1; the DC3 key's primary is version 1 again). Teardown schedules version 1 for destruction again (30 days; restorable again).

Path B (after 2026-11-26, or if the restore is refused): `p2_create_key_versions=true` creates version 2 on each key. Unlike a fresh key, the symmetric DC3 key still has the destroyed version 1 as primary, so a new version is not used until it is set as primary (UNVERIFIED, plan shows `primary` pointing at version 1). Apply in two steps: (1) `-target=module.dc3_kms -target=google_kms_crypto_key_version.dc3 -target=module.t25_kms -target=google_kms_crypto_key_version.t25` with the toggles on; (2) `gcloud kms keys set-primary-version 2 --key=lzv-build-key --keyring=lzv-build-keyring --location=europe-west1 --project=RUNTIME_PROJECT`; (3) the full apply. The asymmetric T25 key has no primary; the data source reads the new version (the version creation may need a moment to reach ENABLED).

The `import` blocks are gated with `for_each` (import blocks cannot use `count`; Terraform 1.17 accepts `for_each` there and the module address `[0]`). After the first apply they are harmless; if the toggle goes off and the keys leave the state again, the next enable imports them again. Fallback if a Terraform version rejects the blocks, one `terraform import` per object:
```
terraform import 'module.dc3_kms[0].google_kms_key_ring.default[0]' projects/RUNTIME_PROJECT/locations/europe-west1/keyRings/lzv-build-keyring
terraform import 'module.dc3_kms[0].google_kms_crypto_key.default["lzv-build-key"]' projects/RUNTIME_PROJECT/locations/europe-west1/keyRings/lzv-build-keyring/cryptoKeys/lzv-build-key
terraform import 'module.t25_kms[0].google_kms_key_ring.default[0]' projects/MCP_PROJECT/locations/europe-west1/keyRings/lzv-binauthz-keyring
terraform import 'module.t25_kms[0].google_kms_crypto_key.default["lzv-attestor-key"]' projects/MCP_PROJECT/locations/europe-west1/keyRings/lzv-binauthz-keyring/cryptoKeys/lzv-attestor-key
```
(Run with the toggles on in `terraform.tfvars`, otherwise the addresses do not exist.)

### v2 Model Armor notes (A)

- Order in run-6: stage 1-0/1-1 apply `enable_v2_model_armor=true` (API + template, T28); stage 1-2 adds `enable_v2_ma_folder_floor=true` (T27) and `enable_v2_ma_vertex=true` (T29); stage 1-3 adds `enable_v2_ma_org_floor=true` (T38).
- T38 needs the folder floor off (a lower-level floor takes precedence over the org floor, so with the folder floor on the org floor is never exercised) and a project without a floor: set `enable_v2_ma_folder_floor=false` in the stage 1-3 apply and run T38 in the data project. T29's project floor is in the runtime project only.
- Floor settings have no delete call in the documented API. Rollback: apply with `v2_ma_floor_enforce.<level> = false`, then switch the floor toggles off (observed in run-6, 2026-10-27, provider 8.8.0: a destroy removes the floor from state only; the floor stays in GCP, non-enforcing, with its filters). gcloud equivalent: `gcloud model-armor floorsettings update --full-uri='organizations/ORG_ID/locations/global/floorSetting' --enable-floor-setting-enforcement=false`.
- Provider 8.8.0 has `google_model_armor_floorsetting` and `google_model_armor_template` (checked with `terraform providers schema -json`); `integrated_services` and `ai_platform_floor_setting` exist. UNVERIFIED: whether the provider reaches the `global` floor and the regional template endpoints without an endpoint override.

### v2 T36 (organization policy, ORG SCOPE)

`t36_mode`: `dryrun` first (human applies, wait up to 15 min for the policy, poll the `cloudaudit.googleapis.com/policy` log up to 30 min), then `enforce`, then `off`. Each change is its own apply. The CEL condition `'lzv-org-test' in resource.labels` is not verified; the API validates it when the constraint is created. While enforced, any bucket created without the label is refused, including Terraform-created ones (DC3 build bucket); the `CREATE`-only method type leaves existing buckets and the seed state bucket untouched. Rollback (any of): `terraform apply -var t36_mode=off`; or
```
gcloud org-policies delete custom.lzvOrgTestBucketLabel --project=EXCEPTION_PROJECT_ID
gcloud org-policies delete custom.lzvOrgTestBucketLabel --organization=ORG_ID
gcloud org-policies delete-custom-constraint custom.lzvOrgTestBucketLabel --organization=ORG_ID
```

### v2 T39 and T39b

T39: `infra-split/` (see its README). T39b: set `vpc_sc_pipeline_egress` in `terraform.tfvars`. Order: dry run first (`vpc_sc_enforced=false`), read the violation, copy its service name and permission/method into the variable, then enforce.

## v2 B: Agent Gateway (T30, T31b, T32), drafted, not applied

Run-7 changes (2026-10-28): `v2_gateway_iap_policy_version` (default "V2": access policy + project policy binding instead of the V1 `roles/iap.egressor` registry grant; needs the `iam.managed.disableAccessPolicyBinding` org policy not enforced on the runtime project and `roles/iam.accessPolicyAdmin`); in `infra/agents`, `agent_g_caa_token_binding_opt_out` (default true). See `tests/RUN-ORDER-run6.md` "Before run 7".

Toggles (default off): `enable_v2_gateway` (+ `v2_gateway_model_armor`, default true, needs `enable_v2_model_armor`) in `infra/`; `deploy_agent_g` in `infra/agents`. File `v2-gateway.tf`; fixtures in `tests/fixtures/gateway/` (`setup.sh`, `teardown.sh`, `mcp/`, `agent_g/`, `toolspec-registered.json`).
Order: `setup.sh preflight` (EU check, first human step; refused for location = area B NOT_TESTED) -> `teardown.sh preflight` -> apply -> `setup.sh build`, `setup.sh deploy` -> wait ~4 min -> agent G (one deploy at a time, 30 min after the previous) -> add G's principal to `dc1_approved_agent_principals` and apply the deny policy (wait 10) -> tests. Reset: `teardown.sh run`, destroy agent G, toggles off, apply. Enable networkservices, networksecurity, agentregistry, iap and modelarmor on the quota (seed) project by hand first. Plan check 2026-10-27 (refresh off, enable_v2_gateway + enable_v2_model_armor): 24 add, 6 destroy that belong to the old SWP leftovers (P1), nothing applied.

### v2 B, run 8 (draft, not applied): gateway VPC egress (`v2-gateway-vpc.tf`)

Run 7 showed that the gateway cannot reach the internal-ingress Cloud Run fixtures without VPC egress (results.md Findings 25). `enable_v2_gateway_vpc = true` (needs `enable_v2_gateway`) adds, in the runtime project: VPC `lzv-gw-vpc`, subnet `lzv-gw-attach` (`v2_gateway_vpc_subnet_cidr`, default 10.77.5.0/28, Private Google Access), network attachment `lzv-gw-attach` (ACCEPT_AUTOMATIC), PSC endpoint for Google APIs `lzvgwapis` (`all-apis`, `v2_gateway_psc_ip`, default 10.77.6.10), private zone `run.app.` with `*.run.app` A to that IP, and `network_config` on the gateway (attachment + DNS peering for `run.app.`). Source: [notes/doc-verification-v2-B-netattach.md](../notes/doc-verification-v2-B-netattach.md).

- `dns.googleapis.com` on the seed (quota) project is managed by Terraform (`google_project_service.v2_gw_seed_dns`, not gated, `disable_on_destroy = false`; it was already enabled when added on 2026-10-30).
- One apply creates the VPC parts and then the gateway (the gateway depends on them). Use `-parallelism=1` as before.
- Check after apply: `gcloud network-services agent-gateways describe lzv-gw --location=europe-west1` shows the attachment; `gcloud compute network-attachments describe lzv-gw-attach --region=europe-west1` shows an ACCEPTED connection endpoint.
- Open at run time: whether the API accepts `network_config` on create (if it demands a connectivity template, switch to `google_network_services_agent_connectivity_template`, `vpc_egress = PRIVATE_RANGES_ONLY`); whether Cloud Run counts the PSC-interface origin as internal (inferred from Google codelabs, not stated). Success sign: the T30 control gets a response and the Cloud Run request log for `lzv-mcp-reg` shows the call.
- Reset: destroy the gateway first; the attachment can stay in use for 5 to 30 minutes, so the subnet/attachment delete may need a second plan later (as with the SWP subnet). Costs of the attachment, PSC endpoint and zone were not found in the docs (small; record from billing).
- Checked 2026-10-30: `terraform validate` OK; untargeted plan with defaults "No changes"; plan with `enable_v2_gateway`, `enable_v2_model_armor`, `enable_v2_gateway_vpc` = 52 to add (the 44 run-7 resources plus 8 VPC/DNS resources), not saved.
