# v3 harness-boundary (T44, T45, T47, T48): two self-owned public HTTP targets, "allowed" and "denied".
# Used as the SWP allowlisted host (T45b) and as the fixed URLs the guarded agent calls.
# Both are the public sample image, served unauthenticated (invoker IAM check disabled), ingress all.
# allUsers run.invoker is NOT used: org-level iam.allowedPolicyMemberDomains allows only our
# customer ID (checked 2026-11-10). On the seed, run.managed.requireInvokerIam is not enforced
# and run.allowedIngress is allowAll (checked 2026-11-10), so invoker_iam_disabled is allowed.
#
# Host project: the quota/seed project (var.quota_project), NOT prj-lzv-outside.
# Why: the folder fldr-lz-validation enforces run.managed.requireInvokerIam (T02) and
# run.allowedIngress = internal (T03); both are inherited by prj-lzv-outside, so allUsers invoker
# and public ingress would be refused there. The seed project sits outside the folder and outside
# the VPC-SC perimeter, so neither policy applies. The default google provider already bills to
# quota_project, so no provider alias is needed (agent-o.tf needs one only because the default
# providers of infra/agents bill to the runtime project).
# Default off. Cost: Cloud Run scales to zero. Destroy the same day.

variable "enable_v3h_targets" {
  description = "v3 harness (T44, T45): create two public unauthenticated Cloud Run services (allowed, denied) in quota_project. Default off."
  type        = bool
  default     = false
}

variable "swp_allowed_host_from_targets" {
  description = "v3 harness (T45b): when true, the SWP allowlist uses the host of the v3h 'allowed' service instead of swp_allowed_host. Needs enable_v3h_targets."
  type        = bool
  default     = false
}

variable "v3h_target_image" {
  description = "Public sample image for both targets."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

resource "google_project_service" "v3h_run" {
  count              = var.enable_v3h_targets || var.enable_v3h_replay ? 1 : 0
  project            = var.quota_project
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

locals {
  v3h_target_names = var.enable_v3h_targets ? toset(["allowed", "denied"]) : toset([])
}

resource "google_cloud_run_v2_service" "v3h_target" {
  for_each             = local.v3h_target_names
  project              = var.quota_project
  location             = var.region
  name                 = "lzv-v3h-${each.key}"
  ingress              = "INGRESS_TRAFFIC_ALL"
  deletion_protection  = false
  invoker_iam_disabled = true

  template {
    containers {
      image = var.v3h_target_image
    }
  }

  depends_on = [google_project_service.v3h_run]
}

locals {
  v3h_allowed_host = var.enable_v3h_targets ? trimprefix(google_cloud_run_v2_service.v3h_target["allowed"].uri, "https://") : null
  v3h_denied_host  = var.enable_v3h_targets ? trimprefix(google_cloud_run_v2_service.v3h_target["denied"].uri, "https://") : null
}

output "v3h_targets" {
  description = "v3 harness: URLs and hosts of the allowed and denied targets; null when off."
  value = var.enable_v3h_targets ? {
    allowed_url  = google_cloud_run_v2_service.v3h_target["allowed"].uri
    denied_url   = google_cloud_run_v2_service.v3h_target["denied"].uri
    allowed_host = local.v3h_allowed_host
    denied_host  = local.v3h_denied_host
  } : null
}

check "v3h_targets_for_swp" {
  assert {
    condition     = !var.swp_allowed_host_from_targets || var.enable_v3h_targets
    error_message = "swp_allowed_host_from_targets needs enable_v3h_targets = true."
  }
}

# T48 replay service (tests/fixtures/replay): the "different workload" that replays the agent's token.
# Seed project: outside the folder and the perimeter, a different project from the agent's.
# Auth ON by default (invoker IAM check enabled). v3h run 1 (2026-11-11, run-1-r2): Cloud Run rejected the agent
# identity's ID token ("The access token could not be verified"), so with human approval the run sets
# v3h_replay_auth=false (invoker_iam_disabled, as for the targets). The service holds no credentials: it only
# forwards the caller's own token to Vertex AI. Seed project, destroyed the same day.
# Invokers: the v3 agent principals (infra/agents output agent_v3) and the operator (T48 control).
# First-apply check: whether org iam.allowedPolicyMemberDomains accepts agent principal:// members.
# Image: built by hand before the apply (human step, RUN-ORDER-v3h block 2):
#   gcloud builds submit tests/fixtures/replay --tag=<v3h_replay_image> --project=<seed>
variable "enable_v3h_replay" {
  description = "v3 harness (T48): deploy the token replay service in quota_project. Default off."
  type        = bool
  default     = false
}

variable "v3h_replay_image" {
  description = "Image of tests/fixtures/replay, built by hand (Artifact Registry in quota_project)."
  type        = string
  default     = null
}

variable "v3h_replay_auth" {
  description = "Invoker IAM check on the replay service. false = invoker_iam_disabled (agent identity ID tokens are not accepted by Cloud Run)."
  type        = bool
  default     = true
}

variable "v3h_replay_invokers" {
  description = "Members allowed to call the replay service: v3 agent principals and the operator (user:...)."
  type        = list(string)
  default     = []
}

# Repo for the replay image (seed). The service is created only once v3h_replay_image is set
# (two applies: repo, then build, then service).
resource "google_project_service" "v3h_replay_ar" {
  count              = var.enable_v3h_replay ? 1 : 0
  project            = var.quota_project
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "v3h_replay" {
  count         = var.enable_v3h_replay ? 1 : 0
  project       = var.quota_project
  location      = var.region
  repository_id = "lzv-v3h"
  format        = "DOCKER"
  depends_on    = [google_project_service.v3h_replay_ar]
}

# T53 v2 / T56 v2 (plan 3b, 2026-11-13): the gateway MCP fixture image is built here, because Cloud Build in the
# runtime project is refused by gcp.restrictNonCmekServices (staging bucket without CMEK). The runtime project's
# Cloud Run service agent pulls it.
resource "google_artifact_registry_repository_iam_member" "v3h_mcp_pull" {
  count      = var.enable_v3h_replay ? 1 : 0
  project    = var.quota_project
  location   = var.region
  repository = google_artifact_registry_repository.v3h_replay[0].repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:service-${module.prj_runtime.number}@serverless-robot-prod.iam.gserviceaccount.com"
}

resource "google_cloud_run_v2_service" "v3h_replay" {
  count                = var.enable_v3h_replay && var.v3h_replay_image != null ? 1 : 0
  project              = var.quota_project
  location             = var.region
  name                 = "lzv-v3h-replay"
  ingress              = "INGRESS_TRAFFIC_ALL"
  deletion_protection  = false
  invoker_iam_disabled = !var.v3h_replay_auth

  template {
    containers {
      image = var.v3h_replay_image
    }
  }

  lifecycle {
    precondition {
      condition     = !var.v3h_replay_auth || length(var.v3h_replay_invokers) > 0
      error_message = "the replay service needs at least one v3h_replay_invokers entry."
    }
  }

  depends_on = [google_project_service.v3h_run]
}

resource "google_cloud_run_v2_service_iam_member" "v3h_replay_invoker" {
  for_each = var.enable_v3h_replay && var.v3h_replay_image != null ? toset(var.v3h_replay_invokers) : toset([])
  project  = var.quota_project
  location = var.region
  name     = google_cloud_run_v2_service.v3h_replay[0].name
  role     = "roles/run.invoker"
  member   = each.value
}

# v3h T49 (plan B10, added 2026-11-11): register the replay service host in the Agent Registry so agent G
# (egress only through the gateway) can reach it. The V2 access policy allows registered destinations
# (destination.is_registered == true), so this adds exactly one allowed host for gateway-bound agents and
# changes nothing for T47 (aiplatform hosts) or T31b (europe-west1 host stays unregistered). Default off.
# Registry entries took about 4 minutes to take effect in run 9 (T31R); the orchestrator waits >= 5 min.
variable "v3h_replay_register_on_gateway" {
  description = "v3h T49: register the replay service URL in the Agent Registry used by the gateway. Default off."
  type        = bool
  default     = false
}

resource "google_agent_registry_service" "v3h_ep_replay" {
  count        = local.gw_on && var.v3h_replay_register_on_gateway && length(google_cloud_run_v2_service.v3h_replay) > 0 ? 1 : 0
  project      = local.gw_project
  location     = var.region
  service_id   = "lzv-ep-v3h-replay"
  display_name = "LZV v3h T49 replay service"
  endpoint_spec {
    type = "NO_SPEC"
  }
  interfaces {
    url              = google_cloud_run_v2_service.v3h_replay[0].uri
    protocol_binding = "HTTP_JSON"
  }
  depends_on = [google_project_service.v2_gw]
}

output "v3h_replay_url" {
  description = "v3 harness (T48): replay service URL (set agent_v3_replay_url to it); null when off."
  value       = length(google_cloud_run_v2_service.v3h_replay) > 0 ? google_cloud_run_v2_service.v3h_replay[0].uri : null
}

# T41 Policy Troubleshooter is billed to the quota project; run 1 (2026-11-11) got PERMISSION_DENIED
# "Policy Troubleshooter API has not been used in project <seed>" (T41 run-1 INCONCLUSIVE, fixture).
resource "google_project_service" "v3h_troubleshooter" {
  count              = var.enable_v3h_targets ? 1 : 0
  project            = var.quota_project
  service            = "policytroubleshooter.googleapis.com"
  disable_on_destroy = false
}
