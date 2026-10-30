# v2 E (T39), root "outside": reads the hierarchy and the outside project, with a quota project that
# is outside the perimeter (the seed). Data sources only: a full plan makes no changes (exit 0).
# The Cloud Storage service account lookup for the outside project is the call that F9 saw refused
# when the quota project was inside the perimeter.

data "terraform_remote_state" "main" {
  backend = "local"
  config = {
    path = var.main_state_path
  }
}

locals {
  outside_project = data.terraform_remote_state.main.outputs.project_ids.outside
  folders         = data.terraform_remote_state.main.outputs.folder_ids
}

data "google_project" "outside" {
  project_id = local.outside_project
}

data "google_storage_project_service_account" "outside" {
  project = local.outside_project
}

data "google_folder" "hierarchy" {
  for_each = local.folders
  folder   = each.value
}

output "outside_project_number" {
  description = "Outside project number, read through the outside quota project."
  value       = data.google_project.outside.number
}

output "outside_gcs_service_account" {
  description = "Cloud Storage service account of the outside project."
  value       = data.google_storage_project_service_account.outside.email_address
}

output "folder_display_names" {
  description = "Folder display names (hierarchy read)."
  value       = { for k, v in data.google_folder.hierarchy : k => v.display_name }
}
