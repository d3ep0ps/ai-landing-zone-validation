# Cost-effective AI landing zone profile, stage 5 of 5 (v3: extra folder policies, Vertex AI budgets, environment folders; no cost).
# Use with: terraform plan -var-file=terraform.tfvars -var-file=profiles/lz-5-reference.tfvars -out=plan-lz-5.tfplan
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
p2_import_existing_kms  = true
p2_create_key_versions  = false
enable_dc3_build_bucket = true
enable_t25_binauthz     = true

# Stage 4. Needs in terraform.tfvars (real IDs, git-ignored):
#   operator_email = "..."
#   vpc_sc_pipeline_egress = {
#     quota_project_number = "<seed project number>"
#     service_name         = "storage.googleapis.com"
#     method_selectors     = ["google.storage.buckets.list", "google.storage.projects.serviceAccounts.getOrCreate", "google.storage.buckets.get", "google.storage.buckets.getIamPolicy"]
#   }   # Finding 22 (run 6, T39b): the egress rule has to be a storage rule. buckets.get + getIamPolicy added 2026-11-03: needed once the stage-3 CMEK bucket exists (dry-run violations, runtime -> seed).
# Apply 4a with -var=vpc_sc_enforced=false (rules land in the dry-run spec only), wait 15 min, check the
# dry-run violation log is empty for the operator, then 4b: vpc_sc_enforced = true, -target=module.vpc_sc.
vpc_sc_operator_ingress = true
vpc_sc_enforced         = true

# Stage 5 (v3, infra/v3-lz.tf). Cumulative from stage 4.
# A: six boolean folder policies (GOV-02, GOV-07, GOV-09, SUP-01). Not retroactive.
enable_v3_org_policies = true
# A: gcp.restrictCmekCryptoKeyProjects: keys live in the runtime and mcp projects. terraform.tfvars must set
#   v3_cmek_key_projects = ["under:projects/<runtime id>", "under:projects/<mcp id>"]
# (plain project IDs also work). An empty list fails validation.
enable_v3_cmek_key_projects = true
# B: modelarmor.googleapis.com is verified as VPC-SC supported (notes/doc-verification-v2-A.md). Terraform manages
# Model Armor from the operator identity outside the perimeter, so the operator ingress rule must cover every
# restricted service (v3_operator_ingress_all_restricted).
v3_extra_restricted_services       = ["modelarmor.googleapis.com"]
v3_operator_ingress_all_restricted = true
# C: budgets alert only, they do not cap spend. Needs billingbudgets.googleapis.com enabled on the quota project (seed).
v3_vertex_billing_service_id = "C7E2-9256-1C43" # public Cloud Billing catalog ID for Vertex AI
enable_v3_budgets            = true
v3_budget_amount_usd         = 10
# D: set v3_env_allowed_models in terraform.tfvars (same model format as allowed_models, with :predict), e.g.
#   v3_env_allowed_models = { sandbox = [...], dev = [...], staging = [...] }
# A missing key means no vertexai.allowedModels policy on that folder.
enable_v3_env_folders = true

# E: VPC lzv-net-vpc + subnet lzv-net-workload (10.78.0.0/24), restricted.googleapis.com DNS/route, egress deny-all,
# in the runtime project (Cloud DNS private zone about USD 0.20/month). IAP ssh ingress stays off.
enable_v3_net        = true
v3_net_allow_iap_ssh = false
