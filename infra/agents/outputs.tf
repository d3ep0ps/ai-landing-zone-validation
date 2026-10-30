# Contract used by tests/T11.sh and tests/T12.sh. The module id is built by the provider and
# may contain the project ID; rebuild the name with the project number from the engine ID.
output "agent_a" {
  description = "Agent A: full resource name (project number) and effective identity; null when not deployed."
  value = var.deploy_agent_a ? {
    id       = "projects/${local.project_number}/locations/${var.region}/reasoningEngines/${element(split("/", module.agent_a[0].id), -1)}"
    identity = module.agent_a[0].identity
  } : null
}

output "agent_b" {
  description = "Agent B: full resource name (project number) and effective identity; null when not deployed."
  value = var.deploy_agent_b ? {
    id       = "projects/${local.project_number}/locations/${var.region}/reasoningEngines/${element(split("/", module.agent_b[0].id), -1)}"
    identity = module.agent_b[0].identity
  } : null
}

output "agent_c" {
  description = "Agent C (PSC interface): full resource name (project number) and effective identity; null when not deployed."
  value = var.deploy_agent_c ? {
    id       = "projects/${local.project_number}/locations/${var.region}/reasoningEngines/${element(split("/", module.agent_c[0].id), -1)}"
    identity = module.agent_c[0].identity
  } : null
}

output "agent_g" {
  description = "Agent G (Agent Gateway egress): full resource name (project number) and effective identity; null when not deployed."
  value = var.deploy_agent_g ? {
    id       = "projects/${local.project_number}/locations/${var.region}/reasoningEngines/${element(split("/", module.agent_g[0].id), -1)}"
    identity = module.agent_g[0].identity
  } : null
}
