# v3h T52 stage "granted" (plan section 3b, human-approved 2026-11-12): grant roles/aiplatform.agentContextEditor on the
# runtime project to the runtime agents principal set, as a team following the docs might, to show whether one agent
# can then read another agent's sessions and memories (no per-agent scoping is documented). Test folder only; the
# orchestrator turns it on for one stage and off again in the same run. Default off.
variable "v3h_t52_grant_context_editor" {
  description = "v3h T52: grant roles/aiplatform.agentContextEditor on the runtime project to the runtime agents principal set. Default off."
  type        = bool
  default     = false
}

resource "google_project_iam_member" "v3h_t52_context_editor" {
  count   = var.v3h_t52_grant_context_editor ? 1 : 0
  project = module.prj_runtime.project_id
  role    = "roles/aiplatform.agentContextEditor"
  member  = "principalSet://agents.global.org-${var.org_id}.system.id.goog/attribute.platformContainer/aiplatform/projects/${module.prj_runtime.number}"
}
