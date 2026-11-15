# v3 harness-boundary baseline (2026-11-10). Applied ON TOP of lz-5-reference.tfvars:
#   terraform plan -var-file=terraform.tfvars -var-file=profiles/lz-5-reference.tfvars -var-file=profiles/v3h-baseline.tfvars
# Why: the lz-5 folder deny (T37) refuses model calls from every agent in the folder except one
# approved principal, so T40b/T41/T44 agent calls would fail for the wrong reason. The perimeter
# starts in dry-run because T44 step 1 needs it. T44/T45 turn controls on per stage (RUN-ORDER-v3h).
enable_v2_folder_deny = false
vpc_sc_enforced       = false
# Step 0 for runs 2 and 3 (human 2026-11-11, F1): Vertex service agents created up front in the per-run projects.
v3h_vertex_service_agent_projects = ["data", "outside"]
# v3h runs 2+: perimeter canary (plans/v3h-automation.md); free, stays on.
enable_v3h_canary = true
