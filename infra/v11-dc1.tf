# v1.1 DC1 (T18): deny aiplatform.googleapis.com/endpoints.predict to every agent identity in the
# runtime project, except an explicit list of approved agents. Default OFF.
# The operator needs roles/iam.denyAdmin (project or org) to create the policy.
# The deny policy takes a few minutes to apply (T18 waits 10 min).

variable "enable_dc1_deny" {
  description = "v1.1 DC1: create the project IAM deny policy on the runtime project. Default off."
  type        = bool
  default     = false
}

variable "dc1_approved_agent_principals" {
  description = "Exception principals for the DC1 deny policy: exact principal://agents.global.org-ORG_ID.system.id.goog/resources/aiplatform/projects/PROJECT_NUMBER/locations/LOCATION/reasoningEngines/ID strings reported by the platform."
  type        = list(string)
  default     = []
}

resource "google_iam_deny_policy" "dc1_agents_predict" {
  count        = var.enable_dc1_deny ? 1 : 0
  provider     = google-beta
  parent       = urlencode("cloudresourcemanager.googleapis.com/projects/${module.prj_runtime.project_id}")
  name         = "lzv-dc1-deny-agent-predict"
  display_name = "DC1: deny endpoints.predict to project agents except approved"

  rules {
    description = "Deny model inference to all agent identities in the runtime project; approved agents are exceptions."
    deny_rule {
      denied_principals    = ["principalSet://agents.global.org-${var.org_id}.system.id.goog/attribute.platformContainer/aiplatform/projects/${module.prj_runtime.number}"]
      exception_principals = var.dc1_approved_agent_principals
      denied_permissions   = ["aiplatform.googleapis.com/endpoints.predict"]
    }
  }
}

output "dc1_deny_policy_name" {
  description = "DC1 deny policy resource name (null when disabled)."
  value       = try(google_iam_deny_policy.dc1_agents_predict[0].name, null)
}
