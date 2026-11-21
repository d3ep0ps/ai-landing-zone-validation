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

# 2026-11-21 (run 10, Track E item 17): the floors, the T28 template and the runtime Model Armor API now
# come from the Fabric modules merged upstream (vendor/fabric 7efa56dbf):
#   - folder floor (T27):  modules/folder  model_armor_floor_setting   (#4361)
#   - project floor (T29): modules/project model_armor_floor_setting   (#4379)
#   - templates (T28/T32): modules/project model_armor_templates       (#4423)
# The inputs below are passed to module.folder_root and module.prj_runtime in main.tf. The moved blocks
# keep the existing GCP objects (no recreate). The org floor (T38) uses modules/organization (#4310)
# below; T38 is org scope (separate approval).

locals {
  v2_ma_filters = {
    pi_and_jailbreak = { confidence_level = "MEDIUM_AND_ABOVE" }
  }
  v2_ma_folder_floor = var.enable_v2_ma_folder_floor ? {
    enforce = var.v2_ma_floor_enforce["folder"]
    filters = local.v2_ma_filters
  } : null
  # Same strictness as the folder floor, so T27 stays valid in this project.
  v2_ma_project_floor = var.enable_v2_ma_vertex ? {
    enforce = var.v2_ma_floor_enforce["project"]
    filters = local.v2_ma_filters
    integrated_services = {
      ai_platform = { mode = "inspect_and_block", cloud_logging = true }
    }
  } : null
  # T28: template used by the screening test.
  v2_ma_templates = var.enable_v2_model_armor ? {
    "lzv-ma-pi" = {
      location = var.region
      filters  = local.v2_ma_filters
      metadata = {
        log_template_operations = true
        log_sanitize_operations = true
      }
    }
  } : {}
}

moved {
  from = google_project_service.v2_ma_runtime[0]
  to   = module.prj_runtime.google_project_service.project_services["modelarmor.googleapis.com"]
}

moved {
  from = google_model_armor_template.v2_pi[0]
  to   = module.prj_runtime.google_model_armor_template.default["lzv-ma-pi"]
}

moved {
  from = google_model_armor_floorsetting.v2_folder[0]
  to   = module.folder_root.google_model_armor_floorsetting.default[0]
}

moved {
  from = google_model_armor_floorsetting.v2_project[0]
  to   = module.prj_runtime.google_model_armor_floorsetting.default[0]
}

# T38 test project: the data project (no project floor, no Vertex use).
resource "google_project_service" "v2_ma_data" {
  count              = var.enable_v2_ma_org_floor ? 1 : 0
  project            = module.prj_data.project_id
  service            = "modelarmor.googleapis.com"
  disable_on_destroy = false
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

# T38: ORGANIZATION-LEVEL floor setting. Org scope: the human applies this alone. Since run 10 it comes
# from Fabric modules/organization model_armor_floor_setting (#4310); the module call sets nothing else.
# Not in state when the code changed (toggle off), so no moved block.
module "org_ma_floor" {
  count           = var.enable_v2_ma_org_floor ? 1 : 0
  source          = "../vendor/fabric/modules/organization"
  organization_id = "organizations/${var.org_id}"
  model_armor_floor_setting = {
    enforce = var.v2_ma_floor_enforce["org"]
    filters = local.v2_ma_filters
  }
}

output "v2_ma_template_id" {
  description = "T28 template resource id (null when disabled)."
  value       = try(module.prj_runtime.model_armor_template_ids["lzv-ma-pi"], null)
}
