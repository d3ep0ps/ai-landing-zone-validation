variable "deploy_agent_a" {
  description = "Deploy agent A (stage 1, before the perimeter is enforced)."
  type        = bool
  default     = false
}

variable "deploy_agent_b" {
  description = "Deploy agent B (stage 3b, after the runtime project is in the enforced perimeter)."
  type        = bool
  default     = false
}

variable "deploy_agent_c" {
  description = "v2 C: deploy agent C with a PSC interface (T33, T34). Needs infra/ with swp_enabled and enable_v2_psci applied. Default off."
  type        = bool
  default     = false
}

variable "deploy_agent_g" {
  description = "v2 B: deploy agent G behind the Agent Gateway (T30, T31b, T32). Needs infra/ applied with enable_v2_gateway = true (output v2_gateway_id) and the MCP fixtures from tests/fixtures/gateway/setup.sh. Default off."
  type        = bool
  default     = false
}

variable "agent_g_caa_token_binding_opt_out" {
  description = "v2 B (run 7, human decision 2026-10-28): set GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=False on agent G, which turns off the default certificate binding of its Agent Identity tokens. Google's Agent Gateway deploy samples set it; the agent-identity docs call the opt-out strongly discouraged. Run 6 (binding on) got 401 UNAUTHENTICATED upstream (F16; notes/doc-verification-v2-B-401.md). Results with true are reported as \"with agent token binding turned off\"."
  type        = bool
  default     = true
}

variable "agent_c_short_attachment_name" {
  description = "v2 C: pass the attachment short name instead of its resource path as network_attachment_id (the codelab uses the name, the Fabric example the path). Fallback if the first deploy rejects the path."
  type        = bool
  default     = false
}

variable "model" {
  description = "Model id from the T04 allowlist, without the :predict suffix. Passed to the agent as LZV_MODEL."
  type        = string
}

variable "region" {
  description = "Agent Runtime region."
  type        = string
  default     = "europe-west1"
}

variable "quota_project" {
  description = "Existing project used for API quota/billing; same value as in infra/. No default on purpose."
  type        = string
}
