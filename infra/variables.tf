variable "org_id" {
  description = "Numeric organization ID (parent of fldr-lz-validation). No default on purpose."
  type        = string
}

variable "billing_account" {
  description = "Billing account ID, format XXXXXX-XXXXXX-XXXXXX. No default on purpose."
  type        = string
}

variable "prefix" {
  description = "Unique project ID prefix; projects become PREFIX-prj-lzv-NAME. Max 14 chars so IDs stay within 30."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,12}[a-z0-9]$", var.prefix))
    error_message = "prefix must be 3-14 chars, lowercase letters, digits, hyphens, starting with a letter."
  }
}

variable "region" {
  description = "Default region."
  type        = string
  default     = "europe-west1"
}

variable "quota_project" {
  description = "Existing project used for API quota/billing (orgpolicy, accesscontextmanager, cloudresourcemanager calls). Decided: the seed project. No default on purpose."
  type        = string
}

# --- Toggles -----------------------------------------------------------------

variable "enable_t05_policy" {
  description = "Apply vertexai.configurableComputerUseToolSafetyPolicies (deny all). Not in the official constraint reference; the API may reject it. Default off."
  type        = bool
  default     = false
}

variable "enable_t06_policy" {
  description = "Apply discoveryengine.managed.disableCustomMcpServerConnector. May already be enforced by Google. Default off."
  type        = bool
  default     = false
}

variable "enable_t07_policy" {
  description = "Apply gcp.restrictNonCmekServices (deny storage.googleapis.com). Order relative to T09/T10 is fixed in Phase 3. Default off."
  type        = bool
  default     = false
}

variable "vpc_sc_enforced" {
  description = "false = perimeter in dry-run (spec only). true = enforced (status set; dry-run spec kept identical)."
  type        = bool
  default     = false
}

variable "vpc_sc_operator_ingress" {
  description = "Stage 3b: add the operator ingress rule (storage + aiplatform) to the perimeter. Default off."
  type        = bool
  default     = false
}

variable "operator_email" {
  description = "Operator account for the ingress rule (set in terraform.tfvars, git-ignored). No default on purpose."
  type        = string
  default     = null
  validation {
    condition     = !var.vpc_sc_operator_ingress || var.operator_email != null
    error_message = "operator_email is required when vpc_sc_operator_ingress = true."
  }
}

variable "log_bucket_locked" {
  description = "Lock the log bucket (IRREVERSIBLE). Apply once with false, verify retention, then set true in a separate apply."
  type        = bool
  default     = false
}

# --- Policy parameters -------------------------------------------------------

variable "allowed_models" {
  description = "vertexai.allowedModels allowlist (T04). Entries need the :predict suffix. No default on purpose: pick a current model from Model Garden at apply time and record it (plus the denied model) before run 1."
  type        = list(string)
}

variable "vpc_sc_restricted_services" {
  description = "Services restricted by the perimeter."
  type        = list(string)
  default     = ["storage.googleapis.com", "aiplatform.googleapis.com"]
}

# --- v2 (run-6), all default off. Toggles are documented in README.md "v2". -----------------------

# P2: key rings/keys that exist in GCP but not in state (they cannot be deleted).
variable "p2_import_existing_kms" {
  description = "P2: add import blocks for the existing key rings and keys (lzv-build-keyring/lzv-build-key in the runtime project, lzv-binauthz-keyring/lzv-attestor-key in the mcp project). Only effective together with enable_dc3_build_bucket / enable_t25_binauthz. Default off."
  type        = bool
  default     = false
}

variable "p2_create_key_versions" {
  description = "P2: create a new key version on the two existing keys (all older versions were destroyed). Needed once, after the import. Default off."
  type        = bool
  default     = false
}

# A: Model Armor
variable "enable_v2_model_armor" {
  description = "v2 A (T28): enable modelarmor.googleapis.com in the runtime project and create the project template lzv-ma-pi (europe-west1, pi_and_jailbreak MEDIUM_AND_ABOVE). Default off."
  type        = bool
  default     = false
}

variable "enable_v2_ma_folder_floor" {
  description = "v2 A (T27): folder floor setting on fldr-lz-validation (pi_and_jailbreak MEDIUM_AND_ABOVE). Requires enable_v2_model_armor. Separate toggle because run-6 applies the template before the floor (stage 1-1 vs 1-2). Default off."
  type        = bool
  default     = false
  validation {
    condition     = !var.enable_v2_ma_folder_floor || var.enable_v2_model_armor
    error_message = "enable_v2_ma_folder_floor requires enable_v2_model_armor = true."
  }
}

variable "enable_v2_ma_vertex" {
  description = "v2 A (T29): project floor setting on the runtime project with the Vertex AI integration (AI_PLATFORM) in INSPECT_AND_BLOCK, and roles/modelarmor.user for the Vertex AI service agent. Requires enable_v2_model_armor. Default off."
  type        = bool
  default     = false
  validation {
    condition     = !var.enable_v2_ma_vertex || var.enable_v2_model_armor
    error_message = "enable_v2_ma_vertex requires enable_v2_model_armor = true."
  }
}

variable "enable_v2_ma_org_floor" {
  description = "v2 A (T38): ORGANIZATION-LEVEL floor setting (org scope; the human applies it alone, one change at a time) and modelarmor.googleapis.com in the data project (the T38 test project). Default off."
  type        = bool
  default     = false
}

variable "v2_ma_floor_enforce" {
  description = "v2 A: enforcement per floor level. Floors cannot be deleted through the API, so rollback is <level> = false + apply before the floor's toggle goes off. Per level so that T38 can turn the folder floor non-enforcing while the org floor enforces (Opus review 2026-10-27)."
  type = object({
    folder  = optional(bool, true)
    project = optional(bool, true)
    org     = optional(bool, true)
  })
  default = {}
}

# C: PSC interface
variable "enable_v2_psci" {
  description = "v2 C (T33, T34): /28 attachment subnet, network attachment (ACCEPT_AUTOMATIC), firewall allows for the attachment CIDR, and roles/compute.networkAdmin for the Vertex AI service agent on the runtime project. Requires swp_enabled. Default off."
  type        = bool
  default     = false
  validation {
    condition     = !var.enable_v2_psci || var.swp_enabled
    error_message = "enable_v2_psci requires swp_enabled = true."
  }
}

variable "v2_psci_subnet_cidr" {
  description = "v2 C: attachment subnet (a /28 is the documented minimum)."
  type        = string
  default     = "10.77.4.0/28"
}

# D: organization scope
variable "t36_mode" {
  description = "v2 D (T36): off = no constraint, no policy; dryrun = custom constraint plus org policy in dry_run_spec only; enforce = org policy in spec only. ORG SCOPE: the human applies each mode alone."
  type        = string
  default     = "off"
  validation {
    condition     = contains(["off", "dryrun", "enforce"], var.t36_mode)
    error_message = "t36_mode must be off, dryrun or enforce."
  }
}

variable "t36_exception_project" {
  description = "v2 D (T36): which test project gets enforce = false (the exception): outside or data."
  type        = string
  default     = "outside"
  validation {
    condition     = contains(["outside", "data"], var.t36_exception_project)
    error_message = "t36_exception_project must be outside or data."
  }
}

variable "enable_v2_folder_deny" {
  description = "v2 D (T37): IAM deny policy on fldr-lz-validation denying aiplatform.googleapis.com/endpoints.predict to every agent identity in the org trust domain, except dc1_approved_agent_principals. Needs roles/iam.denyAdmin on the folder. Default off."
  type        = bool
  default     = false
}

# E: T39b paired control. The control identity must pass the operator ingress rule and be missing
# from the egress rule; otherwise its refusal is an ingress refusal and says nothing about the egress rule.
variable "vpc_sc_operator_ingress_extra_identities" {
  description = "v2 E (T39b): extra identities (e.g. serviceAccount:lzv-t39b-control@...) added to the operator ingress rule. Not added to the egress rule. Default none."
  type        = list(string)
  default     = []
}

# E: T39b
variable "vpc_sc_pipeline_egress" {
  description = "v2 E (T39b): egress rule letting the pipeline identity use a quota project outside the perimeter. null = no rule. identities null = user:operator_email. Applied to the dry-run spec and, when vpc_sc_enforced, to the status. Build the selectors from the dry-run violation before enforcing."
  type = object({
    quota_project_number = string
    identities           = optional(list(string))
    service_name         = optional(string, "serviceusage.googleapis.com")
    method_selectors     = optional(list(string), ["*"])
    permission_selectors = optional(list(string), [])
  })
  default = null
}

# --- v2 B: Agent Gateway (T30, T31b, T32). Default off; README "v2 B". ---------------------------
variable "enable_v2_gateway" {
  description = "v2 B: Agent Gateway lzv-gw (europe-west1), Agent Registry entries, IAP authz extension/policy, registry egress grant, image repository. Run tests/fixtures/gateway/setup.sh preflight first. Default off."
  type        = bool
  default     = false
}

variable "v2_gateway_model_armor" {
  description = "v2 B (T32): Model Armor template lzv-ma-gw, content-authz extension (failOpen false) and policy on the gateway. Needs enable_v2_gateway and enable_v2_model_armor. Default true so the day-3 apply is one step; set false to stage it after T30/T31b."
  type        = bool
  default     = true

  validation {
    condition     = !var.v2_gateway_model_armor || !var.enable_v2_gateway || var.enable_v2_model_armor
    error_message = "v2_gateway_model_armor with enable_v2_gateway requires enable_v2_model_armor = true (API enablement); set v2_gateway_model_armor = false to skip Model Armor."
  }
}

variable "v2_gateway_grant_dep_agent" {
  description = "v2 B: let Terraform create the Service Extensions service agent and grant it the three Model Armor callout roles. false = grant by hand."
  type        = bool
  default     = true
}

variable "v2_gateway_iap_fail_open" {
  description = "v2 B: failOpen of the IAP authz extension. The codelab uses true; false is used here so a broken extension cannot look like an allow."
  type        = bool
  default     = false
}

variable "v2_gateway_iap_policy_version" {
  description = "v2 B: metadata.iapPolicyVersion of the IAP authz extension. V1 = legacy allow policy (roles/iap.egressor on the registry; run 6). V2 = IAM Unified Access Policy (project access policy + policy binding; run 7, human decision 2026-10-28). V2 needs the org policy iam.managed.disableAccessPolicyBinding not enforced on the runtime project, and roles/iam.accessPolicyAdmin for the operator (notes/doc-verification-v2-B-iapv2.md)."
  type        = string
  default     = "V2"
  validation {
    condition     = contains(["V1", "V2"], var.v2_gateway_iap_policy_version)
    error_message = "Must be V1 or V2."
  }
}

variable "v2_gateway_agent_member" {
  description = "v2 B: member that gets roles/iap.egressor on the registry. null = the runtime project's agent principalSet (codelab form), so the grant exists before agent G."
  type        = string
  default     = null
}

variable "v2_gateway_network_attachment" {
  description = "v2 B: optional network attachment URI for the gateway's network_config.egress (needed only if the gateway cannot reach the internal-ingress Cloud Run fixtures without a VPC path; UNVERIFIED). null = no network_config."
  type        = string
  default     = null
}

variable "enable_v2_gateway_vpc" {
  description = "v2 B, run 8 (draft): VPC egress for the gateway (v2-gateway-vpc.tf): VPC lzv-gw-vpc, /28 attachment subnet with Private Google Access, network attachment (ACCEPT_AUTOMATIC), PSC endpoint for Google APIs, private zone run.app. -> endpoint IP, and network_config with DNS peering on the gateway. Needs enable_v2_gateway. Default off (notes/doc-verification-v2-B-netattach.md)."
  type        = bool
  default     = false
  validation {
    condition     = !var.enable_v2_gateway_vpc || var.enable_v2_gateway
    error_message = "enable_v2_gateway_vpc requires enable_v2_gateway = true."
  }
}

variable "v2_gateway_t31r_register_blocked" {
  description = "v2 B, run 9: T31R `post` stage only. Registers T31's blocked host (https://REGION-aiplatform.googleapis.com) in the Agent Registry; nothing else changes. Needs enable_v2_gateway. Default off (tests/RUN-ORDER-run9.md, T31R design)."
  type        = bool
  default     = false
  validation {
    condition     = !var.v2_gateway_t31r_register_blocked || var.enable_v2_gateway
    error_message = "v2_gateway_t31r_register_blocked requires enable_v2_gateway = true."
  }
}

variable "v2_gateway_vpc_subnet_cidr" {
  description = "v2 B, run 8: attachment subnet in lzv-gw-vpc (doc minimum /28; RFC1918)."
  type        = string
  default     = "10.77.5.0/28"
}

variable "v2_gateway_psc_ip" {
  description = "v2 B, run 8: internal IP of the PSC endpoint for Google APIs in lzv-gw-vpc; must be outside every subnet of that VPC. *.run.app resolves to it."
  type        = string
  default     = "10.77.6.10"
}

variable "v2_gateway_mcp_reg_service" {
  description = "v2 B: Cloud Run service name of the registered MCP fixture."
  type        = string
  default     = "lzv-mcp-reg"
}

variable "v2_gateway_mcp_unreg_service" {
  description = "v2 B: Cloud Run service name of the unregistered MCP fixture."
  type        = string
  default     = "lzv-mcp-unreg"
}
