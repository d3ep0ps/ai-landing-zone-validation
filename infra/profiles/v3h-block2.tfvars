# v3h run, block 2 infra (gateway path for T47, self-owned targets, replay service for T48).
# Applied on top of lz-5-reference.tfvars + v3h-baseline.tfvars. Remove (or turn off) at day end.
enable_v2_gateway     = true
enable_v2_gateway_vpc = true
enable_v3h_targets    = true
enable_v3h_replay     = true
v3h_replay_image      = "europe-west1-docker.pkg.dev/PROJECT_6/lzv-v3h/replay@sha256:f9148eefedeaaf9b37672725c6b05b385f25dbfb0a7b530a595b77142a6c9a32"
v3h_replay_invokers = [
  "principalSet://agents.global.org-ORG_ID.system.id.goog/attribute.platformContainer/aiplatform/projects/PROJECT_NUMBER_7",
  "user:USER_1@example.com",
]
enable_v3h_buckets    = true
# v3h run 1 (2026-11-11): Cloud Run does not verify agent identity ID tokens; replay service without invoker check (human-approved).
v3h_replay_auth = false
# v3h T49 (plan 2026-11-11): replay host registered on the gateway for agent G.
v3h_replay_register_on_gateway = true
