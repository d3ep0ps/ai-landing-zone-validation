# v3 harness (T45 action c): copy an object from a bucket inside the perimeter to one outside it.
# Source: the DC3 CMEK build bucket in the runtime project (inside the perimeter) plus one fixed probe object.
# Destination: a new bucket in the outside project (outside the perimeter), CMEK with the outside key
# (the folder enforces CMEK and EU location, T07/T08).
# The runtime project's agents get bucket-level read (source) and create (destination) so that, with the
# platform off, the copy succeeds; with the perimeter on, only VPC-SC can refuse it (not missing IAM).
# Default off. Destroy the same day (force_destroy on the destination).

variable "enable_v3h_buckets" {
  description = "v3 harness (T45c): destination bucket in the outside project, probe object in the DC3 build bucket, bucket-level IAM for the runtime project's agents. Default off."
  type        = bool
  default     = false
}

locals {
  v3h_buckets_on      = var.enable_v3h_buckets && var.enable_dc3_build_bucket && var.enable_outside_cmek
  v3h_runtime_agents  = "principalSet://agents.global.org-${var.org_id}.system.id.goog/attribute.platformContainer/aiplatform/projects/${module.prj_runtime.number}"
  v3h_probe_object    = "lzv-v3h-probe.txt"
  v3h_out_bucket_name = "${module.prj_outside.project_id}-lzv-v3h-out"
}

resource "google_storage_bucket_object" "v3h_probe" {
  count   = local.v3h_buckets_on ? 1 : 0
  bucket  = google_storage_bucket.dc3_build[0].name
  name    = local.v3h_probe_object
  content = "lzv v3h T45c probe object (harmless, fixed content)\n"
}

resource "google_storage_bucket" "v3h_out" {
  count                       = local.v3h_buckets_on ? 1 : 0
  project                     = module.prj_outside.project_id
  name                        = local.v3h_out_bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true
  encryption {
    default_kms_key_name = module.outside_kms[0].key_ids["lzv-outside-key"]
  }
}

resource "google_storage_bucket_iam_member" "v3h_src_read" {
  count  = local.v3h_buckets_on ? 1 : 0
  bucket = google_storage_bucket.dc3_build[0].name
  role   = "roles/storage.objectViewer"
  member = local.v3h_runtime_agents
}

resource "google_storage_bucket_iam_member" "v3h_out_create" {
  count  = local.v3h_buckets_on ? 1 : 0
  bucket = google_storage_bucket.v3h_out[0].name
  role   = "roles/storage.objectCreator"
  member = local.v3h_runtime_agents
}

output "v3h_buckets" {
  description = "v3 harness (T45c): source bucket/object and destination bucket; null when off."
  value = local.v3h_buckets_on ? {
    src_bucket = google_storage_bucket.dc3_build[0].name
    src_object = local.v3h_probe_object
    out_bucket = google_storage_bucket.v3h_out[0].name
  } : null
}

# T45 control (copy inside the perimeter, DEST=src) writes into the source bucket: needs objects.create there.
# Added after v3h run 1 T45 on (control 403 "storage.objects.create"), human-approved 2026-11-11.
resource "google_storage_bucket_iam_member" "v3h_src_create" {
  count  = local.v3h_buckets_on ? 1 : 0
  bucket = google_storage_bucket.dc3_build[0].name
  role   = "roles/storage.objectCreator"
  member = local.v3h_runtime_agents
}
