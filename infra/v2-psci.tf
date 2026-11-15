# v2 C (T33, T34): Agent Runtime with a PSC interface that reaches the Secure Web Proxy of v11-swp.tf.
# The VPC, the /28 attachment subnet (10.77.4.0/28), the ACCEPT_AUTOMATIC attachment and the firewall
# allows are in v11-swp.tf (gated by swp_enabled and enable_v2_psci). This file adds the IAM grant and
# the outputs read by infra/agents (agent C).
#
# Cost: same as T16 (gateway about USD 1.25/hour). Destroy the same day, in this order: agent C
# (infra/agents), then swp_enabled=false. The doc says delete the attachment/subnet only after the
# agent has been unused for at least one hour.
# Docs: a PSC interface of an existing agent cannot be changed; recreate the agent.

resource "google_project_iam_member" "v2_psci_network_admin" {
  count   = local.psci_on ? 1 : 0
  project = module.prj_runtime.project_id
  role    = "roles/compute.networkAdmin" # documented requirement for the Vertex AI service agent
  member  = "serviceAccount:${google_project_service_identity.v2_aiplatform[0].email}"
}

output "v2_psci_attachment_id" {
  description = "v2 C: network attachment resource path (null when disabled)."
  value       = local.psci_on ? module.swp_vpc[0].network_attachment_ids["lzv-psci"] : null
}

output "v2_psci_attachment_name" {
  description = "v2 C: network attachment short name (null when disabled)."
  value       = local.psci_on ? "lzv-psci" : null
}
