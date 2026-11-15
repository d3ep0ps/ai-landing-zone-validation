# v3 harness-boundary root for T40-T43: one fresh runtime project per run, additive IAM only.
# State is per run (see README.md). Reads the folder ID from the infra/ state.
data "terraform_remote_state" "base" {
  backend = "local"
  config = {
    path = var.base_state_path
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
  # Existing-project mode (human decision 2026-11-11: no new projects; one never-used test project
  # per run: r1 mcp, r2 data, r3 outside). Otherwise a fresh project is created.
  existing       = var.existing_project_id != null
  project_id     = local.existing ? data.google_project.existing[0].project_id : module.prj_v3[0].project_id
  project_number = local.existing ? data.google_project.existing[0].number : module.prj_v3[0].number
  services = [
    "aiplatform.googleapis.com",
    "storage.googleapis.com",
    "cloudbuild.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "logging.googleapis.com",
  ]
  agents = {
    "1" = var.deploy_agent_1
    "2" = var.deploy_agent_2
    "3" = var.deploy_agent_3
  }
}

data "google_project" "existing" {
  count      = local.existing ? 1 : 0
  project_id = var.existing_project_id
}

# Existing project: enable what the agents need; never disable on destroy (the base infra/ owns
# the project and other tests use these APIs).
resource "google_project_service" "existing" {
  for_each           = local.existing ? toset(local.services) : toset([])
  project            = var.existing_project_id
  service            = each.value
  disable_on_destroy = false
}

module "prj_v3" {
  count           = local.existing ? 0 : 1
  source          = "../vendor/fabric/modules/project"
  billing_account = var.billing_account
  parent          = data.terraform_remote_state.base.outputs.folder_ids.ai_prod
  prefix          = var.prefix
  name            = "prj-lzv-v3-${var.run}"
  services        = local.services
}

# Additive, operator only. This is the "team Terraform" under test in T40/T42: it never names
# an aiplatform role and grants the agents nothing.
resource "google_project_iam_member" "operator" {
  for_each = toset(var.operator_roles)
  project  = local.project_id
  role     = each.value
  member   = var.operator_member
}

# T40b: authoritative binding that tries to remove the platform's grant.
resource "google_project_iam_binding" "t40b" {
  count   = var.t40b_authoritative ? 1 : 0
  project = local.project_id
  role    = "roles/aiplatform.agentDefaultAccess"
  members = []

  depends_on = [google_project_iam_member.operator, google_project_service.existing]
}

# Identity type is the module default (AGENT_IDENTITY). roles = [] so the module grants nothing.
module "agent" {
  for_each   = { for k, v in local.agents : k => v if v }
  source     = "../vendor/fabric/modules/geap-agent-runtime"
  name       = "lzv-v3-agent-${each.key}"
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
      source_path = var.agent_source_path
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

  depends_on = [google_project_iam_member.operator, google_project_service.existing]
}
