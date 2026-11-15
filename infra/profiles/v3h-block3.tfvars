# v3h block 3 (T44/T45), applied after v3h-block2.tfvars. Edited per stage (RUN-ORDER-v3h steps 21-28).
# Step 21: perimeter enforced, no agent ingress rule.
vpc_sc_enforced = false  # T45 off (D10)
# Step 24: agent ingress identities A and B (terraform output agent_v3 identity)
vpc_sc_agent_ingress_identities = [
  "principal://agents.global.org-ORG_ID.system.id.goog/resources/aiplatform/projects/PROJECT_NUMBER_7/locations/europe-west1/reasoningEngines/AGENT_ID_26",
  "principal://agents.global.org-ORG_ID.system.id.goog/resources/aiplatform/projects/PROJECT_NUMBER_7/locations/europe-west1/reasoningEngines/AGENT_ID_27",
]
# Step 26 (T45 on): SWP + PSC-I (allowlist = v3h allowed target host), project deny with exception v3a only.
swp_enabled                   = true
enable_v2_psci                = true
swp_allowed_host_from_targets = true
enable_dc1_deny               = false  # T45 off
dc1_approved_agent_principals = ["principal://agents.global.org-ORG_ID.system.id.goog/resources/aiplatform/projects/PROJECT_NUMBER_7/locations/europe-west1/reasoningEngines/AGENT_ID_26"]
