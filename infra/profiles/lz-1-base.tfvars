# Cost-effective AI landing zone profile, stage 1 of 4 (project/folder scope, no cost).
# Use with: terraform plan -var-file=terraform.tfvars -var-file=profiles/lz-1-base.tfvars -out=plan-lz-1.tfplan
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
