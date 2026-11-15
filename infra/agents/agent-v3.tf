# v3 harness-boundary (T44, T45, T47, T48): guarded/bypass ADK agents v3a and v3b in the runtime
# project, from one tarball (tests/fixtures/agent_v3/build.sh -> build/source-v3.tar.gz).
# Same module pattern as agent A: AGENT_IDENTITY (module default), roles = [] (grants are the test).
# Pacing (EXECUTION-PLAN E4.3): one agent deploy per apply, 30 minutes apart.

variable "deploy_agent_v3a" {
  description = "v3 harness: deploy agent lzv-v3-a (the approved agent by default). Default off."
  type        = bool
  default     = false
}

variable "deploy_agent_v3b" {
  description = "v3 harness: deploy agent lzv-v3-b (not in the approved list by default). Default off."
  type        = bool
  default     = false
}

variable "agent_v3_approved_agents" {
  description = "LZV_APPROVED_AGENTS: names the guard treats as approved."
  type        = string
  default     = "lzv-v3-a,lzv-v3-a-psci,lzv-v3-a-dep,lzv-v3-a-dep-psci" # approved: a, a_psci (T45 on), a_dep, a_dep_psci (T45d)
}

variable "agent_v3_allowed_url" {
  description = "LZV_ALLOWED_URL when the base state has no v3h_targets output."
  type        = string
  default     = ""
}

variable "agent_v3_internet_url" {
  description = "LZV_INTERNET_URL: a public, non-Google internet host for T44 (TARGET=internet), as T23 used. Added before v3h run 2."
  type        = string
  default     = "https://example.com"
}

variable "agent_v3_denied_url" {
  description = "LZV_DENIED_URL when the base state has no v3h_targets output."
  type        = string
  default     = ""
}

variable "agent_v3_src_bucket" {
  description = "LZV_SRC_BUCKET (GCS copy tool source bucket)."
  type        = string
  default     = ""
}

variable "agent_v3_src_object" {
  description = "LZV_SRC_OBJECT (GCS copy tool source object)."
  type        = string
  default     = ""
}

variable "agent_v3_out_bucket" {
  description = "LZV_OUT_BUCKET (GCS copy tool destination bucket)."
  type        = string
  default     = ""
}

variable "agent_v3_replay_url" {
  description = "LZV_REPLAY_URL (T48 token replay target on the v3 agents; T49 also sets it on agent G)."
  type        = string
  default     = ""
}

variable "agent_v3_use_psci" {
  description = "v3 harness (T45b): attach v3 agents to the PSC-I network attachment and set the proxy variables, as agent C. Needs infra/ swp_enabled and enable_v2_psci."
  type        = bool
  default     = false
}

variable "agent_v3_token_binding_opt_out" {
  description = "v3 harness (T48): set GOOGLE_API_ENABLE_RUNTIME_BOUND_TOKEN=false and the deprecated GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=False on the v3 agents, turning off the default certificate binding of Agent Identity tokens. Nothing else changes. Results with true are reported as 'with agent token binding turned off'."
  type        = bool
  default     = false
}

variable "agent_v3_set" {
  description = "v3h run 2+ (plans/v3h-automation.md): engines from the fixed catalog, deployed side by side: a, b (plain), o (token-binding opt-out), a_psci, b_psci (PSC-I + proxy env), x (T48b sibling, plain); T45d engines a_dep, b_dep, a_dep_psci, b_dep_psci from the dependency tarball. Do not combine with deploy_agent_v3a/v3b (keys a/b would clash)."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for k in var.agent_v3_set : contains(["a", "b", "o", "a_psci", "b_psci", "x", "a_dep", "b_dep", "a_dep_psci", "b_dep_psci"], k)])
    error_message = "allowed keys: a, b, o, a_psci, b_psci, x, a_dep, b_dep, a_dep_psci, b_dep_psci."
  }
}

locals {
  source_path_v3  = "${path.module}/build/source-v3.tar.gz"  # tests/fixtures/agent_v3/build.sh
  source_path_v3d = "${path.module}/build/source-v3d.tar.gz" # tests/fixtures/agent_v3/build.sh dep (T45d)
  v3_targets      = try(data.terraform_remote_state.base.outputs.v3h_targets, null)
  v3_allowed_url  = try(coalesce(try(local.v3_targets.allowed_url, null), var.agent_v3_allowed_url), "")
  v3_denied_url   = try(coalesce(try(local.v3_targets.denied_url, null), var.agent_v3_denied_url), "")
  v3_catalog = {
    a      = { name = "lzv-v3-a", psci = false, opt_out = false }
    b      = { name = "lzv-v3-b", psci = false, opt_out = false }
    o      = { name = "lzv-v3-o", psci = false, opt_out = true }
    a_psci = { name = "lzv-v3-a-psci", psci = true, opt_out = false }
    b_psci = { name = "lzv-v3-b-psci", psci = true, opt_out = false }
    # T48b sibling: same tarball, own engine and certificate.
    x = { name = "lzv-v3-x", psci = false, opt_out = false }
    # T45d: same agent code plus the lzv_helper dependency (separate tarball, separate engines).
    a_dep      = { name = "lzv-v3-a-dep", psci = false, opt_out = false, dep = true }
    b_dep      = { name = "lzv-v3-b-dep", psci = false, opt_out = false, dep = true }
    a_dep_psci = { name = "lzv-v3-a-dep-psci", psci = true, opt_out = false, dep = true }
    b_dep_psci = { name = "lzv-v3-b-dep-psci", psci = true, opt_out = false, dep = true }
  }
  # Run-1 style (one engine changed by global toggles) or run-2 style (catalog), never both for a key.
  v3_legacy = merge(
    var.deploy_agent_v3a ? { a = { name = "lzv-v3-a", psci = var.agent_v3_use_psci, opt_out = var.agent_v3_token_binding_opt_out } } : {},
    var.deploy_agent_v3b ? { b = { name = "lzv-v3-b", psci = var.agent_v3_use_psci, opt_out = var.agent_v3_token_binding_opt_out } } : {},
  )
  v3_agents   = merge(local.v3_legacy, { for k in var.agent_v3_set : k => local.v3_catalog[k] })
  v3_any_psci = anytrue([for k, v in local.v3_agents : v.psci])
}

resource "terraform_data" "agent_v3_inputs" {
  count = local.v3_any_psci || (length(local.v3_legacy) > 0 && length(var.agent_v3_set) > 0) ? 1 : 0
  lifecycle {
    precondition {
      condition     = length(setintersection(keys(local.v3_legacy), var.agent_v3_set)) == 0
      error_message = "agent_v3_set and deploy_agent_v3a/v3b name the same engine key."
    }
    precondition {
      condition     = !local.v3_any_psci || (local.psci_attachment != null && local.proxy_url != null)
      error_message = "agent_v3_use_psci needs infra/ applied with swp_enabled = true and enable_v2_psci = true (outputs v2_psci_attachment_id and swp_proxy_url)."
    }
  }
}

module "agent_v3" {
  for_each   = local.v3_agents
  source     = "../../vendor/fabric/modules/geap-agent-runtime"
  name       = each.value.name
  project_id = local.project_id
  region     = var.region

  enable_deletion_protection = false

  agent_runtime_config = {
    agent_framework = "google-adk"
    class_methods   = local.adk_class_methods
    environment_variables = merge({
      GOOGLE_GENAI_USE_VERTEXAI = "True"
      LZV_MODEL                 = var.model
      LZV_MODEL_LOCATION        = "global"
      LZV_PROJECT_ID            = local.project_id
      LZV_AGENT_NAME            = each.value.name
      LZV_APPROVED_AGENTS       = var.agent_v3_approved_agents
      HARNESS_GUARD             = "on"
      LZV_ALLOWED_URL           = local.v3_allowed_url
      LZV_DENIED_URL            = local.v3_denied_url
      LZV_INTERNET_URL          = var.agent_v3_internet_url
      LZV_SRC_BUCKET            = var.agent_v3_src_bucket
      LZV_SRC_OBJECT            = var.agent_v3_src_object
      LZV_OUT_BUCKET            = var.agent_v3_out_bucket
      LZV_REPLAY_URL            = var.agent_v3_replay_url
      }, each.value.psci ? {
      # agent C sets PROXY_SERVER_URL (explicit proxies= in its tool); HTTPS_PROXY is added for the
      # v3 fixture's HTTP client, same proxy URL.
      PROXY_SERVER_URL = coalesce(local.proxy_url, "unset")
      HTTPS_PROXY      = coalesce(local.proxy_url, "unset")
      # Google API calls (model, Storage) must not go through SWP, or actions a and c would be
      # refused by the proxy allowlist instead of the control under test.
      NO_PROXY = "googleapis.com,.googleapis.com,metadata.google.internal,169.254.169.254"
      } : {}, each.value.opt_out ? {
      # google-auth >= 2.59 reads GOOGLE_API_ENABLE_RUNTIME_BOUND_TOKEN first (only "false" opts out) and
      # falls back to the deprecated var when it is empty; both are set so the opt-out works on any
      # version (notes/doc-verification-v3h.md; google-auth 2.62.1 source, checked 2026-11-10).
      GOOGLE_API_ENABLE_RUNTIME_BOUND_TOKEN                   = "false"
      GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES = "False"
    } : {})
  }

  deployment_config = {
    source_files_config = {
      source_path = try(each.value.dep, false) ? local.source_path_v3d : local.source_path_v3
      python_spec = {
        entrypoint_module = "agent"
        entrypoint_object = "app"
        requirements_file = "requirements.txt"
      }
    }
  }

  networking_config = each.value.psci ? {
    network_attachment_id = local.psci_attachment
  } : null

  service_account_config = {
    roles = []
  }

  depends_on = [terraform_data.agent_v3_inputs]
}

output "agent_v3" {
  description = "v3 agents (a, b, o, a_psci, b_psci): full resource name (project number) and effective identity; empty map when none deployed."
  value = {
    for k, m in module.agent_v3 : k => {
      name     = local.v3_agents[k].name
      id       = "projects/${local.project_number}/locations/${var.region}/reasoningEngines/${element(split("/", m.id), -1)}"
      identity = m.identity
    }
  }
}
