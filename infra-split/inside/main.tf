# v2 E (T39), root "inside": reads only the in-perimeter projects, with an in-perimeter quota project.
# Data sources only: a full plan makes no changes (exit 0) and still calls the APIs. The call that
# F9 saw refused is the Cloud Storage service account lookup (storage.googleapis.com is a restricted
# service); here it is made for in-perimeter projects with an in-perimeter quota project.
# Nothing here is managed, so nothing is duplicated from infra/.

data "terraform_remote_state" "main" {
  backend = "local"
  config = {
    path = var.main_state_path
  }
}

locals {
  inside = {
    runtime = data.terraform_remote_state.main.outputs.project_ids.runtime
    mcp     = data.terraform_remote_state.main.outputs.project_ids.mcp
    data    = data.terraform_remote_state.main.outputs.project_ids.data
  }
}

data "google_project" "inside" {
  for_each   = local.inside
  project_id = each.value
}

# storage.googleapis.com projects.serviceAccount.get: restricted service, in-perimeter project.
data "google_storage_project_service_account" "inside" {
  for_each = local.inside
  project  = each.value
}

output "inside_projects" {
  description = "Project numbers read through the in-perimeter quota project."
  value       = { for k, v in data.google_project.inside : k => v.number }
}

output "inside_gcs_service_accounts" {
  description = "Cloud Storage service accounts of the in-perimeter projects."
  value       = { for k, v in data.google_storage_project_service_account.inside : k => v.email_address }
}
