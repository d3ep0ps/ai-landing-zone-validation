# v4: CMEK key for a bucket in the outside project (T09 with CMEK, run outside the perimeter).
# The existing lzv-build-key lives in the runtime project, inside the enforced perimeter; a bucket in
# prj-lzv-outside cannot use it without a perimeter rule. This key sits next to the bucket instead,
# so the perimeter is not changed. Key ring and key cannot be deleted; teardown destroys the version.

variable "enable_outside_cmek" {
  description = "v4: KMS key ring/key in the outside project (europe-west1) for a CMEK bucket outside the perimeter. Default off. Key ring and key are not deletable."
  type        = bool
  default     = false
}

resource "google_project_service" "outside_kms" {
  count              = var.enable_outside_cmek ? 1 : 0
  project            = module.prj_outside.project_id
  service            = "cloudkms.googleapis.com"
  disable_on_destroy = false
}

data "google_storage_project_service_account" "outside" {
  count   = var.enable_outside_cmek ? 1 : 0
  project = module.prj_outside.project_id
}

# T13 (external spec v2) creates bucket A in the data project (inside the perimeter) with this key.
# The key use crosses the perimeter: blocked when enforced, logged in dry-run.
data "google_storage_project_service_account" "outside_cmek_data" {
  count   = var.enable_outside_cmek ? 1 : 0
  project = module.prj_data.project_id
}

module "outside_kms" {
  count      = var.enable_outside_cmek ? 1 : 0
  source     = "../vendor/fabric/modules/kms"
  depends_on = [google_project_service.outside_kms]
  project_id = module.prj_outside.project_id
  keyring = {
    location = "europe-west1"
    name     = "lzv-outside-keyring"
  }
  keys = {
    "lzv-outside-key" = {
      rotation_period = "7776000s"
      iam = {
        "roles/cloudkms.cryptoKeyEncrypterDecrypter" = [
          "serviceAccount:${data.google_storage_project_service_account.outside[0].email_address}",
          "serviceAccount:${data.google_storage_project_service_account.outside_cmek_data[0].email_address}",
        ]
      }
    }
  }
}

output "outside_cmek_key" {
  description = "Resource name of the outside-project CMEK key (null when the toggle is off)."
  value       = var.enable_outside_cmek ? module.outside_kms[0].keys["lzv-outside-key"].id : null
}
