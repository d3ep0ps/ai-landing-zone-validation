output "project_id" {
  value = local.project_id
}

output "project_number" {
  value = local.project_number
}

output "agents" {
  description = "Full resource names (project number) and identity per deployed agent."
  value = {
    for k, m in module.agent : k => {
      id       = "projects/${local.project_number}/locations/${var.region}/reasoningEngines/${element(split("/", m.id), -1)}"
      identity = m.identity
    }
  }
}

output "expected_agent_principal_set" {
  description = "Principal set the platform is expected to bind roles/aiplatform.agentDefaultAccess to (T40)."
  value       = "principalSet://agents.global.org-${var.org_id}.system.id.goog/attribute.platformContainer/aiplatform/projects/${local.project_number}"
}
