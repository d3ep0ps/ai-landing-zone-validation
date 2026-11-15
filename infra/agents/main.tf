data "terraform_remote_state" "base" {
  backend = "local"
  config = {
    path = "../terraform.tfstate"
  }
}

locals {
  adk_class_methods = jsonencode([
    { name = "create_session", api_mode = "" },
    { name = "get_session", api_mode = "" },
    { name = "async_create_session", api_mode = "async" },
    { name = "stream_query", api_mode = "stream" },
    { name = "async_stream_query", api_mode = "async_stream" },
  ])
  project_id     = data.terraform_remote_state.base.outputs.project_ids.runtime
  project_number = data.terraform_remote_state.base.outputs.project_numbers.runtime
  source_path    = "${path.module}/build/source.tar.gz"

  # v2 C (agent C): attachment and proxy URL come from the infra/ state (enable_v2_psci + swp_enabled).
  source_path_c        = "${path.module}/build/source-c.tar.gz" # tests/fixtures/agent_c/build.sh
  psci_attachment_full = try(data.terraform_remote_state.base.outputs.v2_psci_attachment_id, null)
  psci_attachment_name = try(data.terraform_remote_state.base.outputs.v2_psci_attachment_name, null)
  psci_attachment      = var.agent_c_short_attachment_name ? local.psci_attachment_name : local.psci_attachment_full
  proxy_url            = try(data.terraform_remote_state.base.outputs.swp_proxy_url, null)

  # v2 B (agent G): gateway and MCP fixture URLs come from the infra/ state (enable_v2_gateway).
  source_path_g = var.agent_g_run6 ? "${path.module}/build/source-g-run6.tar.gz" : var.agent_g_unpinned ? "${path.module}/build/source-g-unpinned.tar.gz" : "${path.module}/build/source-g.tar.gz" # tests/fixtures/gateway/agent_g/build.sh (VARIANT=unpinned for T47r, VARIANT=run6 for T47r2)
  gateway_id    = try(data.terraform_remote_state.base.outputs.v2_gateway_id, null)
  gateway_urls  = try(data.terraform_remote_state.base.outputs.v2_gateway_mcp_urls, null)
}

# The identity type is NOT set: the module default (AGENT_IDENTITY) is what T11 tests.
module "agent_a" {
  count      = var.deploy_agent_a ? 1 : 0
  source     = "../../vendor/fabric/modules/geap-agent-runtime"
  name       = "lzv-probe-a"
  project_id = local.project_id
  region     = var.region

  enable_deletion_protection = false

  agent_runtime_config = {
    agent_framework = "google-adk"
    # Required for source deploys (deploy-an-agent docs). Methods exposed by AdkApp; the
    # list and api_mode values follow the Terraform docs example. T14 uses async_stream_query.
    class_methods = local.adk_class_methods
    environment_variables = {
      GOOGLE_GENAI_USE_VERTEXAI = "True"
      LZV_MODEL                 = var.model
      LZV_MODEL_LOCATION        = "global"
    }
  }

  deployment_config = {
    source_files_config = {
      source_path = local.source_path
      python_spec = {
        entrypoint_module = "agent"
        entrypoint_object = "app"
        requirements_file = "requirements.txt"
      }
    }
  }

  # With AGENT_IDENTITY the module would bind these roles to the agent principal at project
  # level (default: aiplatform.user, storage.objectViewer). That would pre-grant inference and
  # break T12, so no roles are granted here.
  service_account_config = {
    roles = []
  }
}

module "agent_b" {
  count      = var.deploy_agent_b ? 1 : 0
  source     = "../../vendor/fabric/modules/geap-agent-runtime"
  name       = "lzv-probe-b"
  project_id = local.project_id
  region     = var.region

  enable_deletion_protection = false

  agent_runtime_config = {
    agent_framework = "google-adk"
    class_methods   = local.adk_class_methods
    environment_variables = {
      GOOGLE_GENAI_USE_VERTEXAI = "True"
      LZV_MODEL                 = var.model
      LZV_MODEL_LOCATION        = "global"
    }
  }

  deployment_config = {
    source_files_config = {
      source_path = local.source_path
      python_spec = {
        entrypoint_module = "agent"
        entrypoint_object = "app"
        requirements_file = "requirements.txt"
      }
    }
  }

  service_account_config = {
    roles = []
  }
}

# v2 C (T33, T34): agent C with a PSC interface. Deploy only after the runtime project is in the
# enforced perimeter and the agent ingress rule exists (docs ordering; C16), and at least 30 minutes
# after the previous deploy (suspension pacing, E4.3). Fixed tools: tests/fixtures/agent_c/agent.py.
resource "terraform_data" "agent_c_inputs" {
  count = var.deploy_agent_c ? 1 : 0
  lifecycle {
    precondition {
      condition     = local.psci_attachment != null && local.proxy_url != null
      error_message = "agent C needs infra/ applied with swp_enabled = true and enable_v2_psci = true (outputs v2_psci_attachment_id and swp_proxy_url)."
    }
  }
}

module "agent_c" {
  count      = var.deploy_agent_c ? 1 : 0
  source     = "../../vendor/fabric/modules/geap-agent-runtime"
  name       = "lzv-probe-c"
  project_id = local.project_id
  region     = var.region

  enable_deletion_protection = false

  agent_runtime_config = {
    agent_framework = "google-adk"
    class_methods   = local.adk_class_methods
    environment_variables = {
      GOOGLE_GENAI_USE_VERTEXAI = "True"
      LZV_MODEL                 = var.model
      LZV_MODEL_LOCATION        = "global"
      PROXY_SERVER_URL          = coalesce(local.proxy_url, "unset") # http://GATEWAY_IP:PORT; used via proxies= in fetch_probe
    }
  }

  deployment_config = {
    source_files_config = {
      source_path = local.source_path_c
      python_spec = {
        entrypoint_module = "agent"
        entrypoint_object = "app"
        requirements_file = "requirements.txt"
      }
    }
  }

  # PSC interface. The proxy is addressed by IP, so no DNS peering.
  networking_config = {
    network_attachment_id = local.psci_attachment
  }

  service_account_config = {
    roles = []
  }

  depends_on = [terraform_data.agent_c_inputs]
}

# v2 B (T30, T31b, T32): agent G, egress bound to the Agent Gateway. Deploy after the gateway, registry
# entries and MCP fixtures exist, and at least 30 minutes after the previous deploy (suspension pacing).
# Add G's principal to dc1_approved_agent_principals (infra/) before the deny-policy apply. The backend
# enforces AGENT_IDENTITY for gateway-bound agents (module default). Changing the binding archives revisions.
locals {
  # v3h run 2 (human 2026-11-11, plans/v3h-automation.md): G with binding on and G with the opt-out are
  # deployed side by side from the same tarball instead of redeploying one engine.
  g_agents = merge(
    var.deploy_agent_g ? { g = { name = "lzv-probe-g", opt_out = var.agent_g_caa_token_binding_opt_out } } : {},
    var.deploy_agent_g_optout ? { g_optout = { name = "lzv-probe-g-optout", opt_out = true } } : {},
  )
}

resource "terraform_data" "agent_g_inputs" {
  count = length(local.g_agents) > 0 ? 1 : 0
  lifecycle {
    precondition {
      condition     = local.gateway_id != null && local.gateway_urls != null
      error_message = "agent G needs infra/ applied with enable_v2_gateway = true (outputs v2_gateway_id and v2_gateway_mcp_urls)."
    }
  }
}

module "agent_g" {
  for_each   = local.g_agents
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
      MCP_REG_URL               = try(local.gateway_urls.registered, "unset")
      MCP_UNREG_URL             = try(local.gateway_urls.unregistered, "unset")
      }, var.agent_v3_replay_url != "" ? {
      # v3h T49: replay service URL (same service as T48); reachable only if infra/ registers it on the gateway.
      LZV_REPLAY_URL = var.agent_v3_replay_url
      } : {}, each.value.opt_out ? {
      # Run-7 change (F16): opt out of the default CAA token binding, as in Google's gateway deploy samples.
      # google-auth >= 2.59 reads GOOGLE_API_ENABLE_RUNTIME_BOUND_TOKEN first (only "false" opts out) and
      # falls back to the deprecated var when it is empty; both are set so the opt-out works on any
      # version (notes/doc-verification-v3h.md; google-auth 2.62.1 source, checked 2026-11-10).
      GOOGLE_API_ENABLE_RUNTIME_BOUND_TOKEN                   = "false"
      GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES = "False"
    } : {})
  }

  deployment_config = {
    source_files_config = {
      source_path = local.source_path_g
      python_spec = {
        entrypoint_module = "agent"
        entrypoint_object = "app"
        requirements_file = "requirements.txt"
      }
    }
  }

  networking_config = {
    agent_gateways = {
      egress = local.gateway_id
    }
  }

  service_account_config = {
    roles = []
  }

  depends_on = [terraform_data.agent_g_inputs]
}
