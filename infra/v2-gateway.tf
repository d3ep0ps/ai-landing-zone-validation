# v2 B (T30, T31b, T32): Agent Gateway (egress, Agent-to-Anywhere), Agent Registry entries, IAP
# request-authz extension/policy, Model Armor content-authz extension/policy. Default OFF.
#
# Region: var.region (europe-west1; the test folder allows EU locations only). EU availability of Agent
# Gateway is UNKNOWN (docs list no regions). Run tests/fixtures/gateway/setup.sh preflight FIRST; if the
# region is refused, area B is NOT_TESTED and none of this is applied.
#
# NOT created here (scripts, tests/fixtures/gateway/setup.sh): the container image and the two Cloud Run
# services. Their URLs are deterministic (https://NAME-PROJECT_NUMBER.REGION.run.app), so the registry
# entries can be created first.
#
# Operator, by hand, before the first apply: enable on the QUOTA project (seed) the APIs these resources
# call (networkservices, networksecurity, agentregistry, iap, modelarmor), as the providers bill to it.
#
# Agent Gateway has no DRY_RUN/ENFORCED field in the provider schema. The docs mention a dry-run mode for the
# IAP authz policy; UNVERIFIED how it is set, so the policy created here is the default (enforcing) one.

locals {
  gw_on          = var.enable_v2_gateway
  gw_project     = module.prj_runtime.project_id
  gw_number      = module.prj_runtime.number
  gw_registry    = "//agentregistry.googleapis.com/projects/${local.gw_project}/locations/${var.region}" # codelab form; provider doc shows a {version} segment, UNVERIFIED
  gw_reg_url     = "https://${var.v2_gateway_mcp_reg_service}-${local.gw_number}.${var.region}.run.app"
  gw_unreg_url   = "https://${var.v2_gateway_mcp_unreg_service}-${local.gw_number}.${var.region}.run.app"
  gw_agent_set   = "principalSet://agents.global.org-${var.org_id}.system.id.goog/attribute.platformContainer/aiplatform/projects/${local.gw_number}"
  gw_agent_grant = coalesce(var.v2_gateway_agent_member, local.gw_agent_set)
  gw_ma_tpl      = "projects/${local.gw_project}/locations/${var.region}/templates/lzv-ma-gw"
  gw_dep_agent   = "serviceAccount:service-${local.gw_number}@gcp-sa-dep.iam.gserviceaccount.com"
  gw_iap_v1      = local.gw_on && var.v2_gateway_iap_policy_version == "V1"
  gw_iap_v2      = local.gw_on && var.v2_gateway_iap_policy_version == "V2"
}

resource "google_project_service" "v2_gw" {
  for_each = local.gw_on ? toset([
    "compute.googleapis.com",
    "networksecurity.googleapis.com",
    "networkservices.googleapis.com",
    "iap.googleapis.com",
    "iam.googleapis.com", # V2 access policies (run 7)
    "agentregistry.googleapis.com",
    "modelarmor.googleapis.com",
    "artifactregistry.googleapis.com",
  ]) : toset([])
  project            = local.gw_project
  service            = each.key
  disable_on_destroy = false
}

# Image repository for the MCP fixture (setup.sh builds into it). Destroy removes the images with it.
resource "google_artifact_registry_repository" "v2_gw" {
  count         = local.gw_on ? 1 : 0
  project       = local.gw_project
  location      = var.region
  repository_id = "lzv-gw"
  format        = "DOCKER"
  depends_on    = [google_project_service.v2_gw]
}

# --- Agent Registry: one MCP server (registered), the model endpoint, the essential logging endpoint ---

resource "google_agent_registry_service" "v2_mcp_reg" {
  count        = local.gw_on ? 1 : 0
  project      = local.gw_project
  location     = var.region
  service_id   = var.v2_gateway_mcp_reg_service
  display_name = "LZV registered MCP fixture"
  mcp_server_spec {
    type    = "TOOL_SPEC"
    content = file("${path.module}/../tests/fixtures/gateway/toolspec-registered.json")
  }
  interfaces {
    url              = "${local.gw_reg_url}/mcp"
    protocol_binding = "JSONRPC"
  }
  depends_on = [google_project_service.v2_gw]
}

# T31b "allowed endpoint": exactly one model endpoint is registered, the global Vertex AI host. The regional
# host (europe-west1-aiplatform.googleapis.com) is deliberately NOT registered.
resource "google_agent_registry_service" "v2_ep_aiplatform" {
  count        = local.gw_on ? 1 : 0
  project      = local.gw_project
  location     = var.region
  service_id   = "lzv-ep-aiplatform"
  display_name = "LZV allowed model endpoint"
  endpoint_spec {
    type = "NO_SPEC"
  }
  interfaces {
    url              = "https://aiplatform.googleapis.com"
    protocol_binding = "HTTP_JSON"
  }
  depends_on = [google_project_service.v2_gw]
}

# T31R (run 9) `post` stage only: register T31's blocked host, so the only change between T31R `pre` and
# `post` is the registry (tests/RUN-ORDER-run9.md, T31R design). Default off; turned off again at 9-1d.
# No IAP policy change: the V2 rule allows registered destinations (destination.is_registered == true).
resource "google_agent_registry_service" "v2_ep_t31r_blocked" {
  count        = local.gw_on && var.v2_gateway_t31r_register_blocked ? 1 : 0
  project      = local.gw_project
  location     = var.region
  service_id   = "lzv-ep-t31r-blocked"
  display_name = "LZV T31R post: T31 blocked endpoint registered"
  endpoint_spec {
    type = "NO_SPEC"
  }
  interfaces {
    url              = "https://${var.region}-aiplatform.googleapis.com"
    protocol_binding = "HTTP_JSON"
  }
  depends_on = [google_project_service.v2_gw]
}

# Docs: aiplatform.googleapis.com and logging.googleapis.com must be allowed before an agent is bound, else
# every invocation fails with 498. Logging is not a model endpoint.
# Added in run-6 day 3 after T30/T32 were INCONCLUSIVE: the gateway refused (403) agent G's ADK session
# calls to https://europe-west1-aiplatform.mtls.googleapis.com/v1beta1/projects/N/locations/europe-west1/
# reasoningEngines/G/sessions (gateway_requests log). Hostname matching is exact and the mTLS variant must be
# registered (docs: scale/runtime/agent-gateway-runtime-deploy, fetched 2026-10-28). Kept narrow so that
# T31's blocked endpoint (europe-west1-aiplatform.googleapis.com, no mTLS) stays unregistered.
resource "google_agent_registry_service" "v2_ep_sessions" {
  count        = local.gw_on ? 1 : 0
  project      = local.gw_project
  location     = var.region
  service_id   = "lzv-ep-sessions"
  display_name = "LZV agent sessions (mTLS, this project's reasoning engines)"
  endpoint_spec {
    type = "NO_SPEC"
  }
  interfaces {
    url              = "https://${var.region}-aiplatform.mtls.googleapis.com/v1beta1/projects/${local.gw_number}/locations/${var.region}/reasoningEngines"
    protocol_binding = "HTTP_JSON"
  }
  depends_on = [google_project_service.v2_gw]
}

# mTLS twin of the allowed model host (aiplatform.googleapis.com), same reason.
resource "google_agent_registry_service" "v2_ep_aiplatform_mtls" {
  count        = local.gw_on ? 1 : 0
  project      = local.gw_project
  location     = var.region
  service_id   = "lzv-ep-aiplatform-mtls"
  display_name = "LZV allowed model endpoint (mTLS)"
  endpoint_spec {
    type = "NO_SPEC"
  }
  interfaces {
    url              = "https://aiplatform.mtls.googleapis.com"
    protocol_binding = "HTTP_JSON"
  }
  depends_on = [google_project_service.v2_gw]
}

# Essential platform endpoints (docs: scale/runtime/agent-gateway-runtime-deploy, step 6, fetched 2026-10-28):
# exact hostnames, standard and mTLS. Added in run-6 day 3 before the agent G redeploy ("allowlist the
# essential APIs before performing this binding step"). Deviation: europe-west1-aiplatform.googleapis.com is
# NOT registered, because it is T31's blocked endpoint. Entries already defined elsewhere are not repeated
# (aiplatform.googleapis.com, aiplatform.mtls.googleapis.com, logging.googleapis.com).
locals {
  gw_essential_endpoints = local.gw_on ? {
    "agentregistry"       = "https://agentregistry.googleapis.com"
    "logging-mtls"        = "https://logging.mtls.googleapis.com"
    "telemetry"           = "https://telemetry.googleapis.com"
    "telemetry-mtls"      = "https://telemetry.mtls.googleapis.com"
    "cloudtrace"          = "https://cloudtrace.googleapis.com"
    "cloudtrace-mtls"     = "https://cloudtrace.mtls.googleapis.com"
    "monitoring"          = "https://monitoring.googleapis.com"
    "monitoring-mtls"     = "https://monitoring.mtls.googleapis.com"
    "secretmanager"       = "https://secretmanager.googleapis.com"
    "secretmanager-mtls"  = "https://secretmanager.mtls.googleapis.com"
    "crm"                 = "https://cloudresourcemanager.googleapis.com"
    "crm-mtls"            = "https://cloudresourcemanager.mtls.googleapis.com"
    "iamcredentials"      = "https://iamcredentials.googleapis.com"
    "iamcredentials-mtls" = "https://iamcredentials.mtls.googleapis.com"
    "aiplatform-rep"      = "https://aiplatform.${var.region}.rep.googleapis.com"
    "aiplatform-reg-mtls" = "https://${var.region}-aiplatform.mtls.googleapis.com"
  } : {}
}

resource "google_agent_registry_service" "v2_ep_essential" {
  for_each     = local.gw_essential_endpoints
  project      = local.gw_project
  location     = var.region
  service_id   = "lzv-ep-${each.key}"
  display_name = "LZV essential endpoint ${each.key}"
  endpoint_spec {
    type = "NO_SPEC"
  }
  interfaces {
    url              = each.value
    protocol_binding = "HTTP_JSON"
  }
  depends_on = [google_project_service.v2_gw]
}

resource "google_agent_registry_service" "v2_ep_logging" {
  count        = local.gw_on ? 1 : 0
  project      = local.gw_project
  location     = var.region
  service_id   = "lzv-ep-logging"
  display_name = "LZV essential logging endpoint"
  endpoint_spec {
    type = "NO_SPEC"
  }
  interfaces {
    url              = "https://logging.googleapis.com"
    protocol_binding = "HTTP_JSON"
  }
  depends_on = [google_project_service.v2_gw]
}

# Registry-level grant (codelab: roles/iap.egressor on the registry resource) to the project's agent
# principalSet, so it exists before agent G does. Unregistered destinations stay denied by default.
# V1 only (run 6). Under V2 it is removed, so any ALLOW comes from the access policy below.
resource "google_iap_agent_registry_iam_member" "v2_egress" {
  count      = local.gw_iap_v1 ? 1 : 0
  project    = local.gw_project
  location   = var.region
  role       = "roles/iap.egressor"
  member     = local.gw_agent_grant
  depends_on = [google_project_service.v2_gw]
}

# --- Gateway ---

resource "google_network_services_agent_gateway" "v2" {
  count      = local.gw_on ? 1 : 0
  project    = local.gw_project
  location   = var.region
  name       = "lzv-gw"
  protocols  = ["MCP"]
  registries = [local.gw_registry]
  google_managed {
    governed_access_path = "AGENT_TO_ANYWHERE"
  }
  # Run 8 (v2-gateway-vpc.tf): with enable_v2_gateway_vpc the gateway gets the attachment and DNS peering for
  # run.app. at create (networkAttachment is immutable). var.v2_gateway_network_attachment still overrides
  # the attachment; without the VPC toggle there is no DNS peering (run-6/7 shape).
  dynamic "network_config" {
    for_each = (local.gw_vpc_on || var.v2_gateway_network_attachment != null) ? [1] : []
    content {
      egress {
        network_attachment = coalesce(var.v2_gateway_network_attachment, try(google_compute_network_attachment.v2_gw[0].id, null))
      }
      dynamic "dns_peering_config" {
        for_each = local.gw_vpc_on ? [1] : []
        content {
          domains        = ["run.app."]
          target_project = local.gw_project
          target_network = local.gw_vpc_network
        }
      }
    }
  }
  depends_on = [
    google_project_service.v2_gw,
    google_agent_registry_service.v2_mcp_reg,
    google_dns_record_set.v2_gw_runapp,
    google_compute_global_forwarding_rule.v2_gw_psc,
  ]
}

# IAP request authz (T30, T31b). Codelab values: failOpen true, timeout 1s. For a deny test fail-open would
# hide a broken extension as "allowed"; this draft uses var.v2_gateway_iap_fail_open (default false).
resource "google_network_services_authz_extension" "v2_iap" {
  count     = local.gw_on ? 1 : 0
  project   = local.gw_project
  location  = var.region
  name      = "lzv-gw-iap"
  service   = "iap.googleapis.com"
  fail_open = var.v2_gateway_iap_fail_open
  timeout   = "1s"
  # The API requires metadata.iapPolicyVersion (run-6 day 3: 400 without it). V1 = IAM allow policy
  # (the roles/iap.egressor grant on the registry, as designed in E3; run 6). V2 = IAM Unified Access
  # Policy (google_iam_project_access_policy.v2_egress below; run 7). The docs recommend V2.
  # Docs: gemini-enterprise-agent-platform/govern/gateways/delegate-authorization (fetched 2026-10-28).
  metadata = {
    iapPolicyVersion = var.v2_gateway_iap_policy_version
  }
  # load_balancing_scheme is not set: the codelab YAML has none (UNVERIFIED that the API accepts that).
  depends_on = [google_project_service.v2_gw]
}

resource "google_network_security_authz_policy" "v2_iap" {
  count          = local.gw_on ? 1 : 0
  project        = local.gw_project
  location       = var.region
  name           = "lzv-gw-iap-policy"
  action         = "CUSTOM"
  policy_profile = "REQUEST_AUTHZ"
  target {
    resources = [google_network_services_agent_gateway.v2[0].id]
  }
  custom_provider {
    authz_extension {
      resources = [google_network_services_authz_extension.v2_iap[0].id]
    }
  }
}

# IAP V2 (run 7): an access policy that allows the agent principalSet to egress via IAP to registered
# destinations in the gateway's registry location, bound to the runtime project. Same intent as the V1
# grant: registered = allowed, anything else has no ALLOW rule. Schema checked against provider 8.8.0;
# the permission and the condition attributes are from the delegate-authorization and cel-attributes-uap
# pages (notes/doc-verification-v2-B-iapv2.md). Propagation delay is not documented.
resource "google_iam_project_access_policy" "v2_egress" {
  count            = local.gw_iap_v2 ? 1 : 0
  project          = local.gw_project
  location         = "global"
  access_policy_id = "lzv-gw-egress"
  display_name     = "LZV gateway egress (T30, T31b)"
  details {
    rules {
      description = "LZV agents may call registered destinations through the gateway"
      effect      = "ALLOW"
      principals  = [local.gw_agent_grant]
      operation {
        permissions = ["iap.googleapis.com/resources.egressViaIAP"]
      }
      conditions {
        service    = "iap.googleapis.com"
        expression = "destination.is_registered == true && destination.agent_registry.location == '${var.region}'"
      }
    }
  }
  depends_on = [google_project_service.v2_gw]
}

# The binding is refused while iam.managed.disableAccessPolicyBinding is enforced on the project
# (human step before the apply). Delete order is binding first, then policy (Terraform handles it).
resource "google_iam_projects_policy_binding" "v2_egress" {
  count             = local.gw_iap_v2 ? 1 : 0
  project           = local.gw_project
  location          = "global"
  policy_binding_id = "lzv-gw-egress"
  display_name      = "LZV gateway egress"
  policy_kind       = "ACCESS"
  policy            = "projects/${local.gw_project}/locations/global/accessPolicies/${google_iam_project_access_policy.v2_egress[0].access_policy_id}"
  target {
    resource = "//cloudresourcemanager.googleapis.com/projects/${local.gw_project}"
  }
}

# --- Model Armor at the gateway (T32) ---

resource "google_model_armor_template" "v2_gw" {
  count       = local.gw_on && var.v2_gateway_model_armor ? 1 : 0
  project     = local.gw_project
  location    = var.region
  template_id = "lzv-ma-gw"
  filter_config {
    pi_and_jailbreak_filter_settings {
      filter_enforcement = "ENABLED"
      confidence_level   = "MEDIUM_AND_ABOVE"
    }
  }
  template_metadata {
    enforcement_type        = "INSPECT_AND_BLOCK"
    log_template_operations = true
    log_sanitize_operations = true
  }
  depends_on = [google_project_service.v2_gw]
}

# Service Extensions service agent (egress): calloutUser + serviceUsageConsumer in the gateway project,
# modelarmor.user in the template project (same project here). The agent may not exist before the first
# extension: if the identity resource fails, create the extension by hand once or set
# v2_gateway_grant_dep_agent=false and grant the three roles manually (UNVERIFIED service name).
resource "google_project_service_identity" "v2_gw_dep" {
  count    = local.gw_on && var.v2_gateway_model_armor && var.v2_gateway_grant_dep_agent ? 1 : 0
  provider = google-beta
  project  = local.gw_project
  service  = "networkservices.googleapis.com"
}

resource "google_project_iam_member" "v2_gw_dep" {
  for_each = local.gw_on && var.v2_gateway_model_armor && var.v2_gateway_grant_dep_agent ? toset([
    "roles/modelarmor.calloutUser",
    "roles/serviceusage.serviceUsageConsumer",
    "roles/modelarmor.user",
  ]) : toset([])
  project    = local.gw_project
  role       = each.key
  member     = local.gw_dep_agent
  depends_on = [google_project_service_identity.v2_gw_dep]
}

resource "google_network_services_authz_extension" "v2_ma" {
  count     = local.gw_on && var.v2_gateway_model_armor ? 1 : 0
  project   = local.gw_project
  location  = var.region
  name      = "lzv-gw-ma"
  service   = "modelarmor.${var.region}.rep.googleapis.com"
  fail_open = false # T32 expected result is locked with failOpen false
  timeout   = "10s" # provider range 10 ms to 10 s; codelab value not recorded
  metadata = {
    model_armor_settings = jsonencode([{
      request_template_id  = local.gw_ma_tpl
      response_template_id = local.gw_ma_tpl
    }])
  }
  depends_on = [google_model_armor_template.v2_gw, google_project_iam_member.v2_gw_dep]
}

resource "google_network_security_authz_policy" "v2_ma" {
  count          = local.gw_on && var.v2_gateway_model_armor ? 1 : 0
  project        = local.gw_project
  location       = var.region
  name           = "lzv-gw-ma-policy"
  action         = "CUSTOM"
  policy_profile = "CONTENT_AUTHZ"
  target {
    resources = [google_network_services_agent_gateway.v2[0].id]
  }
  custom_provider {
    authz_extension {
      resources = [google_network_services_authz_extension.v2_ma[0].id]
    }
  }
}

output "v2_gateway_id" {
  description = "v2 B: agent gateway resource name (null when disabled). Read by infra/agents (agent G)."
  value       = try(google_network_services_agent_gateway.v2[0].id, null)
}

output "v2_gateway_mcp_urls" {
  description = "v2 B: deterministic Cloud Run URLs of the MCP fixtures (services are created by setup.sh)."
  value       = local.gw_on ? { registered = local.gw_reg_url, unregistered = local.gw_unreg_url } : null
}

output "v2_gateway_agent_member" {
  description = "v2 B: agent principal allowed to egress via IAP (V1: roles/iap.egressor on the registry; V2: ALLOW rule in access policy lzv-gw-egress)."
  value       = local.gw_on ? local.gw_agent_grant : null
}
