variable "run" {
  description = "Run label, for example r1. Project name becomes prj-lzv-v3-RUN."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]{1,6}$", var.run))
    error_message = "run must be 1-6 lowercase letters or digits (keeps the project ID within 30 chars)."
  }
}

variable "org_id" {
  description = "Numeric organization ID. Used only to build the expected agent principalSet string. No default."
  type        = string
}

variable "billing_account" {
  description = "Billing account ID for the run project. No default."
  type        = string
}

variable "prefix" {
  description = "Project ID prefix (same as infra/). Max 14 chars."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,12}[a-z0-9]$", var.prefix))
    error_message = "prefix must be 3-14 chars, lowercase letters, digits, hyphens, starting with a letter."
  }
}

variable "quota_project" {
  description = "Existing project used for API quota/billing of provider calls (the seed project). No default."
  type        = string
}

variable "base_state_path" {
  description = "Path to the infra/ local state, read for folder_ids.ai_prod."
  type        = string
  default     = "../infra/terraform.tfstate"
}

variable "region" {
  description = "Region for agents. T40-T43 default europe-west1; run 3 may use europe-west4."
  type        = string
  default     = "europe-west1"
}

variable "operator_member" {
  description = "IAM member string for the operator that deploys agents, e.g. user:NAME@example.com. Granted var.operator_roles additively. No default."
  type        = string
}

variable "operator_roles" {
  description = "Roles granted to the operator (additive, google_project_iam_member). Must NOT contain roles/aiplatform.* so the T42 Rego gate stays a clean test of out-of-band grants (roles/editor already carries the Vertex AI permissions needed to create reasoning engines)."
  type        = list(string)
  default = [
    "roles/editor",                          # create engine, staging bucket, Cloud Build for source deploys
    "roles/iam.serviceAccountUser",          # actAs for build/runtime service accounts
    "roles/resourcemanager.projectIamAdmin", # lets the operator read/diff policy and run the T40b binding (set-iam-policy)
  ]
}

variable "t40b_authoritative" {
  description = "T40b: add authoritative google_project_iam_binding for roles/aiplatform.agentDefaultAccess with members = []. Turn on only after agent 1 works."
  type        = bool
  default     = false
}

variable "deploy_agent_1" {
  description = "Deploy agent 1 (T40)."
  type        = bool
  default     = false
}

variable "deploy_agent_2" {
  description = "Deploy agent 2 (T41, T40b step 5)."
  type        = bool
  default     = false
}

variable "deploy_agent_3" {
  description = "Deploy agent 3 (T43, after agents 1 and 2 are deleted)."
  type        = bool
  default     = false
}

variable "agent_source_path" {
  description = "ONE source tarball used for all three agents (tests/fixtures/agent_v3/build.sh writes it; path relative to infra-v3h/; record sha256)."
  type        = string
  default     = "build/source.tar.gz"
}

variable "model" {
  description = "Model id passed to the agent as LZV_MODEL."
  type        = string
  default     = "gemini-3.5-flash"
}

variable "existing_project_id" {
  description = "Use this existing project instead of creating prj-lzv-v3-<run> (2026-11-11: r1 <prefix>-prj-lzv-mcp, r2 -data, r3 -outside). It must never have hosted an agent (no agentDefaultAccess binding)."
  type        = string
  default     = null
}
