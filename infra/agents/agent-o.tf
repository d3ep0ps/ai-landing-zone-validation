# v4 agent O: same probe source as A/B, deployed in the seed project, outside the test folder and
# the perimeter. Its own provider alias bills calls to the seed project; the default providers bill
# to the runtime project, which is inside the enforced perimeter.
# Pacing (EXECUTION-PLAN E4.3): one agent deploy per apply, 30 minutes apart.

variable "deploy_agent_o" {
  description = "v4: deploy agent O in outside_project (outside the perimeter). Default off."
  type        = bool
  default     = false
}

variable "outside_project" {
  description = "Project for agent O, outside the test folder and the perimeter."
  type        = string
  default     = "PROJECT_6"
}

variable "agent_o_roles" {
  description = "Project roles for agent O's identity in outside_project. aiplatform.user lets it call the model."
  type        = list(string)
  default     = ["roles/aiplatform.user"]
}

provider "google" {
  alias                 = "outside"
  region                = var.region
  user_project_override = true
  billing_project       = var.outside_project
}

provider "google-beta" {
  alias                 = "outside"
  region                = var.region
  user_project_override = true
  billing_project       = var.outside_project
}

data "google_project" "outside" {
  count      = var.deploy_agent_o ? 1 : 0
  provider   = google.outside
  project_id = var.outside_project
}

module "agent_o" {
  count  = var.deploy_agent_o ? 1 : 0
  source = "../../vendor/fabric/modules/geap-agent-runtime"
  providers = {
    google      = google.outside
    google-beta = google-beta.outside
  }
  name       = "lzv-probe-o"
  project_id = var.outside_project
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
    roles = var.agent_o_roles
  }
}

output "agent_o" {
  description = "Agent O (outside the perimeter): full resource name (project number) and identity; null when not deployed."
  value = var.deploy_agent_o ? {
    id       = "projects/${data.google_project.outside[0].number}/locations/${var.region}/reasoningEngines/${element(split("/", module.agent_o[0].id), -1)}"
    identity = module.agent_o[0].identity
  } : null
}

# Everything an external tester needs in one place: base inputs plus agent engine IDs.
output "tester_inputs" {
  description = "infra/ tester_inputs plus agent engine IDs (T18: A and B inside, O outside the perimeter)."
  value = merge(try(data.terraform_remote_state.base.outputs.tester_inputs, {}), {
    agents = {
      a_inside  = var.deploy_agent_a ? "projects/${local.project_number}/locations/${var.region}/reasoningEngines/${element(split("/", module.agent_a[0].id), -1)}" : null
      b_inside  = var.deploy_agent_b ? "projects/${local.project_number}/locations/${var.region}/reasoningEngines/${element(split("/", module.agent_b[0].id), -1)}" : null
      o_outside = var.deploy_agent_o ? "projects/${data.google_project.outside[0].number}/locations/${var.region}/reasoningEngines/${element(split("/", module.agent_o[0].id), -1)}" : null
    }
    agent_billing_project = {
      a_b = var.quota_project
      o   = var.outside_project
    }
  })
}
