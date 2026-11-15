# Cost-effective AI landing zone profile, stage 3 of 4 (CMEK build bucket, Binary Authorization; about USD 0.15/month for 2 key versions).
# Use with: terraform plan -var-file=terraform.tfvars -var-file=profiles/lz-3-cmek.tfvars -out=plan-lz-3.tfplan
# Each stage file is cumulative: pass only the highest stage you have reached.
# No real IDs in this file (they stay in the git-ignored terraform.tfvars).

# Paid or agent items: always off in this profile.
swp_enabled                      = false
enable_v2_psci                   = false
enable_v2_gateway                = false
enable_v2_gateway_vpc            = false
v2_gateway_t31r_register_blocked = false
vpc_sc_agent_ingress_identities  = []

# Org-scope items: off (each needs its own human approval and a separate apply).
t36_mode               = "off"
enable_v2_ma_org_floor = false

# Stage 1: Model Armor API + project template (T28), Admin Activity sink to the locked bucket (DC4).
enable_v2_model_armor = true
enable_dc4_sink       = true
log_bucket_locked     = true

# Stage 2: folder org policies (T05, T06, T07), Model Armor floors enforcing at folder (T27) and
# runtime project with Vertex AI integration (T29), folder IAM deny on agent predict (T37).
# T07 denies non-CMEK Cloud Storage in the folder: any later bucket must use CMEK (stage 3).
# Floors cannot be deleted: rollback is v2_ma_floor_enforce.<level> = false, apply, then toggles off.
enable_t05_policy         = true
enable_t06_policy         = true
enable_t07_policy         = true
enable_v2_ma_folder_floor = true
enable_v2_ma_vertex       = true
v2_ma_floor_enforce       = { folder = true, project = true, org = false }
enable_v2_folder_deny     = true
enable_dc1_deny           = false

# Stage 3 (optional). BEFORE planning: the human restores and enables version 1 of both existing
# keys (infra/README.md "v2 P2", path A, valid until 2026-11-26). After that date use path B.
p2_import_existing_kms = true
p2_create_key_versions = false
enable_dc3_build_bucket = true
enable_t25_binauthz     = true
