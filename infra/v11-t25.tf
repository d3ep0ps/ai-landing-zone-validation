# v1.1 T25 support: Binary Authorization REQUIRE_ATTESTATION in the mcp project (where the Cloud Run
# tests run, see tests/T17.sh). Default OFF.
#
# Created when enabled: 2 APIs (containeranalysis, cloudkms; binaryauthorization is already on the
# project), KMS key ring + EC_SIGN_P256_SHA256 key (NOT deletable), Container Analysis note,
# attestor with the KMS public key, and the project policy.
# Default-admission rule: while enabled it is REQUIRE_ATTESTATION + ENFORCED_BLOCK_AND_AUDIT_LOG, so
# every Cloud Run deploy in mcp that uses --binary-authorization=default needs an attestation (this
# includes the T17 positive control). Turning the toggle off destroys the policy resource, and the
# provider then restores the default policy (ALWAYS_ALLOW). Verify with
# `gcloud container binauthz policy export --project=PROJECT`.
# Attestation creation by the operator needs roles/containeranalysis.notes.attacher (note),
# roles/containeranalysis.occurrences.editor and roles/cloudkms.signerVerifier (granted below to
# operator_email when set).

variable "enable_t25_binauthz" {
  description = "v1.1 T25: create the Binary Authorization policy, attestor, note and KMS signing key in the mcp project. Default off. The KMS key ring and key cannot be deleted."
  type        = bool
  default     = false
}

resource "google_project_service" "t25" {
  for_each           = var.enable_t25_binauthz ? toset(["containeranalysis.googleapis.com", "cloudkms.googleapis.com"]) : toset([])
  project            = module.prj_mcp.project_id
  service            = each.value
  disable_on_destroy = false
}

module "t25_kms" {
  count      = var.enable_t25_binauthz ? 1 : 0
  source     = "../vendor/fabric/modules/kms"
  depends_on = [google_project_service.t25]
  project_id = module.prj_mcp.project_id
  keyring = {
    location = var.region
    name     = "lzv-binauthz-keyring"
  }
  keys = {
    "lzv-attestor-key" = {
      purpose = "ASYMMETRIC_SIGN"
      version_template = {
        algorithm        = "EC_SIGN_P256_SHA256"
        protection_level = "SOFTWARE"
      }
      iam = var.operator_email == null ? {} : {
        "roles/cloudkms.signerVerifier" = ["user:${var.operator_email}"]
      }
    }
  }
}

# v2 P2: with p2_create_key_versions the data source reads the version created by
# google_kms_crypto_key_version.t25 (version 1 of the existing key is destroyed).
data "google_kms_crypto_key_version" "t25" {
  count      = var.enable_t25_binauthz ? 1 : 0
  crypto_key = module.t25_kms[0].keys["lzv-attestor-key"].id
  version    = var.p2_create_key_versions ? tonumber(element(split("/", google_kms_crypto_key_version.t25[0].name), -1)) : 1
}

module "t25_binauthz" {
  count      = var.enable_t25_binauthz ? 1 : 0
  source     = "../vendor/fabric/modules/binauthz"
  depends_on = [google_project_service.t25]
  project_id = module.prj_mcp.project_id
  default_admission_rule = {
    evaluation_mode  = "REQUIRE_ATTESTATION"
    enforcement_mode = "ENFORCED_BLOCK_AND_AUDIT_LOG"
    attestors        = ["lzv-attestor"]
  }
  attestors_config = {
    "lzv-attestor" = {
      note_reference  = null # module creates the Container Analysis note "lzv-attestor-note"
      iam             = {}
      pgp_public_keys = null
      pkix_public_keys = [{
        id                  = "//cloudkms.googleapis.com/v1/${trimprefix(data.google_kms_crypto_key_version.t25[0].name, "//cloudkms.googleapis.com/v1/")}" # Binary Authorization KMS key ID format (Opus review)
        public_key_pem      = data.google_kms_crypto_key_version.t25[0].public_key[0].pem
        signature_algorithm = "ECDSA_P256_SHA256"
      }]
    }
  }
}

output "t25_attestor_name" {
  description = "T25 attestor resource name (null when disabled)."
  value       = try(module.t25_binauthz[0].attestors["lzv-attestor"].id, null)
}

output "t25_note_name" {
  description = "T25 Container Analysis note id (null when disabled)."
  value       = try(module.t25_binauthz[0].notes["lzv-attestor"].id, null)
}

output "t25_key_version_id" {
  description = "T25 KMS key version resource name (null when disabled)."
  value       = try(data.google_kms_crypto_key_version.t25[0].name, null)
}
