# v1.1 DC4 (T24): folder-level aggregated sink of Admin Activity audit logs to the locked log bucket
# in the logging project (module.prj_data). Default OFF.
# The operator needs roles/logging.configWriter on the folder (logging.sinks.create) and the right
# to set IAM on the destination project.

variable "enable_dc4_sink" {
  description = "v1.1 DC4: create the aggregated Admin Activity sink on fldr-lz-validation to the log bucket. Default off."
  type        = bool
  default     = false
}

resource "google_logging_folder_sink" "dc4_admin_activity" {
  count            = var.enable_dc4_sink ? 1 : 0
  name             = "lzv-dc4-admin-activity"
  folder           = module.folder_root.id
  include_children = true
  destination      = "logging.googleapis.com/${module.log_bucket.id}"
  filter           = "logName:\"cloudaudit.googleapis.com%2Factivity\""
  description      = "v1.1 DC4: Admin Activity audit logs to the locked bucket"
}

# Doc (notes/doc-verification.md T24): bucket in another project needs logWriter and bucketWriter.
resource "google_project_iam_member" "dc4_bucket_writer" {
  for_each = var.enable_dc4_sink ? toset(["roles/logging.bucketWriter", "roles/logging.logWriter"]) : toset([])
  project  = module.prj_data.project_id
  role     = each.value
  member   = google_logging_folder_sink.dc4_admin_activity[0].writer_identity
}

output "dc4_sink_writer_identity" {
  description = "DC4 sink writer identity (null when disabled)."
  value       = try(google_logging_folder_sink.dc4_admin_activity[0].writer_identity, null)
}
