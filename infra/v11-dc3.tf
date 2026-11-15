# v1.1 DC3 (T21): regional CMEK Cloud Build staging bucket. Default OFF.
# KMS key rings and keys CANNOT be deleted (key versions can be scheduled for destruction).

variable "enable_dc3_build_bucket" {
  description = "v1.1 DC3: create KMS key ring/key and the CMEK build staging bucket (europe-west1, runtime project). Default off. Key ring and key are not deletable."
  type        = bool
  default     = false
}

variable "dc3_build_service_accounts" {
  description = "Extra service account emails (no prefix) granted objectAdmin on the build bucket. The legacy Cloud Build SA of the mcp project is always included."
  type        = list(string)
  default     = []
}

locals {
  dc3_location = "europe-west1"
  dc3_build_members = [
    for e in distinct(concat(
      [
        # Builds run in the mcp project (tests/T10.sh). Only its legacy Cloud Build SA is certain to
        # exist (cloudbuild API enabled; compute API is not, so no compute default SA). Add others
        # via dc3_build_service_accounts once they exist. (Opus review 2026-10-25)
        "${module.prj_mcp.number}@cloudbuild.gserviceaccount.com",
      ],
      var.dc3_build_service_accounts,
    )) : "serviceAccount:${e}"
  ]
}

data "google_storage_project_service_account" "dc3" {
  count   = var.enable_dc3_build_bucket ? 1 : 0
  project = module.prj_runtime.project_id
}

module "dc3_kms" {
  count      = var.enable_dc3_build_bucket ? 1 : 0
  source     = "../vendor/fabric/modules/kms"
  depends_on = [google_project_service.dc3_kms]
  project_id = module.prj_runtime.project_id
  keyring = {
    location = local.dc3_location
    name     = "lzv-build-keyring"
  }
  keys = {
    "lzv-build-key" = {
      rotation_period = "7776000s"
      iam = {
        "roles/cloudkms.cryptoKeyEncrypterDecrypter" = [
          "serviceAccount:${data.google_storage_project_service_account.dc3[0].email_address}",
        ]
      }
    }
  }
}

resource "google_project_service" "dc3_kms" {
  count              = var.enable_dc3_build_bucket ? 1 : 0
  project            = module.prj_runtime.project_id
  service            = "cloudkms.googleapis.com"
  disable_on_destroy = false
}

resource "google_storage_bucket" "dc3_build" {
  count                       = var.enable_dc3_build_bucket ? 1 : 0
  project                     = module.prj_runtime.project_id
  name                        = "${module.prj_runtime.project_id}-lzv-build-cmek"
  location                    = local.dc3_location
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true
  # Wait for the key IAM grant to the Cloud Storage service agent, not only the key (Opus review).
  depends_on = [module.dc3_kms, google_kms_crypto_key_version.dc3] # v2 P2: key needs an enabled version
  encryption {
    default_kms_key_name = module.dc3_kms[0].key_ids["lzv-build-key"]
  }
}

resource "google_storage_bucket_iam_member" "dc3_build_rw" {
  for_each = var.enable_dc3_build_bucket ? toset(local.dc3_build_members) : toset([])
  bucket   = google_storage_bucket.dc3_build[0].name
  role     = "roles/storage.admin" # Cloud Build docs: build SA needs Storage Admin unless legacy SA in the same project (T21 run-4-r2)
  member   = each.value
}

output "dc3_build_bucket" {
  description = "DC3 CMEK build staging bucket name (null when disabled)."
  value       = try(google_storage_bucket.dc3_build[0].name, null)
}
