locals {
  common_services = [
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
  ]

  # Folder-wide policies (fldr-lz-validation); inherited by fldr-ai-prod.
  org_policies_base = {
    # T01
    "iam.managed.disableServiceAccountKeyCreation" = { rules = [{ enforce = true }] }
    # T02
    "run.managed.requireInvokerIam" = { rules = [{ enforce = true }] }
    # T03
    "run.allowedIngress" = { rules = [{ allow = { values = ["internal"] } }] }
    # T08
    "gcp.resourceLocations" = { rules = [{ allow = { values = ["in:eu-locations"] } }] }
    # T09
    "storage.publicAccessPrevention" = { rules = [{ enforce = true }] }
    # T17
    "run.allowedBinaryAuthorizationPolicies" = { rules = [{ allow = { values = ["default"] } }] }
  }

  org_policies_toggled = merge(
    # T05: unknown to the official reference; toggle off by default
    var.enable_t05_policy ? {
      "vertexai.configurableComputerUseToolSafetyPolicies" = { rules = [{ deny = { all = true } }] }
    } : {},
    # T06
    var.enable_t06_policy ? {
      "discoveryengine.managed.disableCustomMcpServerConnector" = { rules = [{ enforce = true }] }
    } : {},
    # T07 (also the precondition of T10)
    var.enable_t07_policy ? {
      "gcp.restrictNonCmekServices" = { rules = [{ deny = { values = ["storage.googleapis.com"] } }] }
    } : {},
  )
}

# --- Folders -----------------------------------------------------------------

module "folder_root" {
  source       = "../vendor/fabric/modules/folder"
  parent       = "organizations/${var.org_id}"
  name         = "fldr-lz-validation"
  org_policies = merge(local.org_policies_base, local.org_policies_toggled)
}

module "folder_ai_prod" {
  source = "../vendor/fabric/modules/folder"
  parent = module.folder_root.id
  name   = "fldr-ai-prod"
  org_policies = {
    # T04: scoped to the "prod" folder, i.e. only prj-lzv-runtime
    "vertexai.allowedModels" = { rules = [{ allow = { values = var.allowed_models } }] }
  }
}

# --- Projects ----------------------------------------------------------------

module "prj_runtime" {
  source          = "../vendor/fabric/modules/project"
  billing_account = var.billing_account
  parent          = module.folder_ai_prod.id
  prefix          = var.prefix
  name            = "prj-lzv-runtime2"
  services = concat(local.common_services, [
    "aiplatform.googleapis.com",
    "run.googleapis.com",
    "storage.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "binaryauthorization.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudasset.googleapis.com",
  ])
}

module "prj_mcp" {
  source          = "../vendor/fabric/modules/project"
  billing_account = var.billing_account
  parent          = module.folder_root.id
  prefix          = var.prefix
  name            = "prj-lzv-mcp"
  services = concat(local.common_services, [
    "run.googleapis.com",
    "storage.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "binaryauthorization.googleapis.com",
  ])
}

module "prj_data" {
  source          = "../vendor/fabric/modules/project"
  billing_account = var.billing_account
  parent          = module.folder_root.id
  prefix          = var.prefix
  name            = "prj-lzv-data"
  services = concat(local.common_services, [
    "storage.googleapis.com",
    "cloudkms.googleapis.com", # optional CMEK positive control for T07
  ])
}

module "prj_outside" {
  source          = "../vendor/fabric/modules/project"
  billing_account = var.billing_account
  parent          = module.folder_root.id
  prefix          = var.prefix
  name            = "prj-lzv-outside"
  services = concat(local.common_services, [
    "storage.googleapis.com",
  ])
}

# --- Locked log bucket (T15) -------------------------------------------------

module "log_bucket" {
  source      = "../vendor/fabric/modules/logging-bucket"
  parent_type = "project"
  parent      = module.prj_data.project_id # moved from prj-lzv-logging (billing quota, 2026-10-23)
  name        = "lzv-locked-logs"
  location    = var.region
  retention   = 1
  locked      = var.log_bucket_locked # IRREVERSIBLE once true
}
