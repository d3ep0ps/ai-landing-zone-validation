# v2 A (T27, T28, T29, T38): Model Armor. All behind toggles, default off. Region of the template:
# europe-west1 (the test folder allows EU locations only). Floor settings live in "global".
#
# Operator roles (the human grants them; Terraform grants none to the operator):
#   - templates, project API:        roles/modelarmor.admin on the runtime project (plus serviceusage rights)
#   - project floor (T29):           roles/modelarmor.floorSettingsAdmin on the runtime project
#   - folder floor (T27):            roles/modelarmor.floorSettingsAdmin on fldr-lz-validation
#   - org floor (T38, ORG SCOPE):    roles/modelarmor.floorSettingsAdmin on the organization
#   - callers of sanitizeUserPrompt: roles/modelarmor.user on the template project
# modelarmor.googleapis.com must also be enabled on the quota project (seed): the providers send
# user_project_override with billing_project = quota_project. Enable it there by hand once.
#
# Precedence (docs): a lower-level floor setting takes precedence over a higher-level one, so for
# T38 the folder floor must be off (enable_v2_ma_folder_floor = false) and the T38 test project
# (the data project) must have no project floor setting.
#
# Floor settings cannot be deleted through the API; set v2_ma_floor_enforce.<level> = false, apply, then
# switch the toggles off (the provider only removes the resource from state, UNVERIFIED).

locals {
  v2_ma_filter_pi = {
    filter_enforcement = "ENABLED"
    confidence_level   = "MEDIUM_AND_ABOVE"
  }
}

resource "google_project_service" "v2_ma_runtime" {
  count              = var.enable_v2_model_armor ? 1 : 0
  project            = module.prj_runtime.project_id
  service            = "modelarmor.googleapis.com"
  disable_on_destroy = false
}

# T38 test project: the data project (no project floor, no Vertex use).
resource "google_project_service" "v2_ma_data" {
  count              = var.enable_v2_ma_org_floor ? 1 : 0
  project            = module.prj_data.project_id
  service            = "modelarmor.googleapis.com"
  disable_on_destroy = false
}

# T28: template used by the screening test.
resource "google_model_armor_template" "v2_pi" {
  count       = var.enable_v2_model_armor ? 1 : 0
  project     = module.prj_runtime.project_id
  location    = var.region
  template_id = "lzv-ma-pi"

  filter_config {
    pi_and_jailbreak_filter_settings {
      filter_enforcement = local.v2_ma_filter_pi.filter_enforcement
      confidence_level   = local.v2_ma_filter_pi.confidence_level
    }
  }

  template_metadata {
    log_template_operations = true
    log_sanitize_operations = true
  }

  depends_on = [google_project_service.v2_ma_runtime]
}

# T27: folder floor setting.
resource "google_model_armor_floorsetting" "v2_folder" {
  count                            = var.enable_v2_ma_folder_floor ? 1 : 0
  parent                           = module.folder_root.id # folders/NUMBER
  location                         = "global"
  enable_floor_setting_enforcement = var.v2_ma_floor_enforce["folder"]

  filter_config {
    pi_and_jailbreak_filter_settings {
      filter_enforcement = local.v2_ma_filter_pi.filter_enforcement
      confidence_level   = local.v2_ma_filter_pi.confidence_level
    }
  }
}

# T29: project floor setting with the Vertex AI integration (applies to generateContent calls
# without model_armor_config). Same strictness as the folder floor, so T27 stays valid in this
# project.
resource "google_model_armor_floorsetting" "v2_project" {
  count                            = var.enable_v2_ma_vertex ? 1 : 0
  parent                           = "projects/${module.prj_runtime.project_id}"
  location                         = "global"
  enable_floor_setting_enforcement = var.v2_ma_floor_enforce["project"]
  integrated_services              = ["AI_PLATFORM"]

  filter_config {
    pi_and_jailbreak_filter_settings {
      filter_enforcement = local.v2_ma_filter_pi.filter_enforcement
      confidence_level   = local.v2_ma_filter_pi.confidence_level
    }
  }

  ai_platform_floor_setting {
    inspect_and_block    = true
    enable_cloud_logging = true
  }

  depends_on = [google_project_service.v2_ma_runtime]
}

# The Vertex AI service agent must exist before it can be granted a role.
resource "google_project_service_identity" "v2_aiplatform" {
  count    = var.enable_v2_ma_vertex || var.enable_v2_psci ? 1 : 0
  provider = google-beta
  project  = module.prj_runtime.project_id
  service  = "aiplatform.googleapis.com"
}

resource "google_project_iam_member" "v2_ma_vertex_user" {
  count   = var.enable_v2_ma_vertex ? 1 : 0
  project = module.prj_runtime.project_id
  role    = "roles/modelarmor.user"
  member  = "serviceAccount:${google_project_service_identity.v2_aiplatform[0].email}"
}

# T38: ORGANIZATION-LEVEL floor setting. Org scope: the human applies this alone.
resource "google_model_armor_floorsetting" "v2_org" {
  count                            = var.enable_v2_ma_org_floor ? 1 : 0
  parent                           = "organizations/${var.org_id}"
  location                         = "global"
  enable_floor_setting_enforcement = var.v2_ma_floor_enforce["org"]

  filter_config {
    pi_and_jailbreak_filter_settings {
      filter_enforcement = local.v2_ma_filter_pi.filter_enforcement
      confidence_level   = local.v2_ma_filter_pi.confidence_level
    }
  }
}

output "v2_ma_template_id" {
  description = "T28 template resource id (null when disabled)."
  value       = try(google_model_armor_template.v2_pi[0].id, null)
}
