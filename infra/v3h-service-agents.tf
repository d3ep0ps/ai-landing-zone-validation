# v3 harness, step 0 (human decision 2026-11-11, after v3h run 1 finding F1): create the Vertex AI
# service agents in the per-run project BEFORE the first agent deploy, so T40's IAM diff isolates the
# platform grant (roles/aiplatform.agentDefaultAccess) instead of also showing the service-agent
# bindings that the first deploy adds.
# Done in the base landing zone (this root), not in infra-v3h: infra-v3h is the "team Terraform" under
# test in T40/T42 and must not name an aiplatform role.
# Docs (gcp-verifier 2026-11-11):
# - gemini-enterprise-agent-platform/build/runtime/setup "Manually generate the default service agent":
#   `services identity create --service=aiplatform.googleapis.com` also creates the Reasoning Engine
#   service agent (gcp-sa-aiplatform-re), although the response shows only the Vertex AI service agent.
# - iam/docs/create-service-agents: agents created on request "aren't automatically granted roles";
#   roles cannot be granted before the agent exists (hence depends_on).
# google_project_service_identity is google-beta only. disable_on_destroy=false: other roots use the API.

variable "v3h_vertex_service_agent_projects" {
  description = "Per-run v3h projects (keys: mcp, data, outside) whose Vertex AI service agents are created up front with their usual roles. Default none."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for k in var.v3h_vertex_service_agent_projects : contains(["mcp", "data", "outside"], k)])
    error_message = "allowed keys: mcp, data, outside."
  }
}

locals {
  v3h_sa_projects = {
    for k in var.v3h_vertex_service_agent_projects : k => {
      mcp     = { id = module.prj_mcp.project_id, number = module.prj_mcp.number }
      data    = { id = module.prj_data.project_id, number = module.prj_data.number }
      outside = { id = module.prj_outside.project_id, number = module.prj_outside.number }
    }[k]
  }
  v3h_sa_bindings = merge([
    for k, p in local.v3h_sa_projects : {
      "${k}/serviceAgent" = {
        project = p.id
        role    = "roles/aiplatform.serviceAgent"
        member  = "serviceAccount:service-${p.number}@gcp-sa-aiplatform.iam.gserviceaccount.com"
      }
      "${k}/reasoningEngineServiceAgent" = {
        project = p.id
        role    = "roles/aiplatform.reasoningEngineServiceAgent"
        member  = "serviceAccount:service-${p.number}@gcp-sa-aiplatform-re.iam.gserviceaccount.com"
      }
    }
  ]...)
}

resource "google_project_service" "v3h_sa_aiplatform" {
  for_each           = local.v3h_sa_projects
  project            = each.value.id
  service            = "aiplatform.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service_identity" "v3h_aiplatform" {
  for_each   = local.v3h_sa_projects
  provider   = google-beta
  project    = each.value.id
  service    = "aiplatform.googleapis.com"
  depends_on = [google_project_service.v3h_sa_aiplatform]
}

resource "google_project_iam_member" "v3h_vertex_service_agents" {
  for_each   = local.v3h_sa_bindings
  project    = each.value.project
  role       = each.value.role
  member     = each.value.member
  depends_on = [google_project_service_identity.v3h_aiplatform]
}
