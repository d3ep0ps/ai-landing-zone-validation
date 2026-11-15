# v3h runs 2+ (human 2026-11-11, plans/v3h-automation.md): a canary service account that tells the
# orchestrator when a perimeter change is live, without polling the call under test.
# - Lives in the outside project (test folder, outside the perimeter), so impersonating it never crosses
#   the perimeter. Used only via impersonation by the operator (no keys).
# - Enforcement live: canary lists the runtime build bucket -> 403 with a VPC-SC unique identifier.
#   Dry-run / not in perimeter: 200.
# - Ingress rule live: the canary identity is added next to the agent identities in the agent ingress
#   rule; its aiplatform reasoningEngines.list on the runtime project turns from VPC-SC 403 into 200.
# It is not in the operator ingress rule. Default off.

variable "enable_v3h_canary" {
  description = "v3h: create the perimeter canary service account (outside project) and its read-only grants. Default off."
  type        = bool
  default     = false
}

locals {
  v3h_canary_on = var.enable_v3h_canary && var.enable_dc3_build_bucket
}

resource "google_service_account" "v3h_canary" {
  count        = local.v3h_canary_on ? 1 : 0
  project      = module.prj_outside.project_id
  account_id   = "lzv-v3h-canary"
  display_name = "v3h perimeter canary (impersonation only, no keys)"
}

resource "google_service_account_iam_member" "v3h_canary_operator" {
  count              = local.v3h_canary_on ? 1 : 0
  service_account_id = google_service_account.v3h_canary[0].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "user:${var.operator_email}"
}

resource "google_storage_bucket_iam_member" "v3h_canary_bucket" {
  count  = local.v3h_canary_on ? 1 : 0
  bucket = google_storage_bucket.dc3_build[0].name
  role   = "roles/storage.objectViewer"
  member = google_service_account.v3h_canary[0].member
}

resource "google_project_iam_member" "v3h_canary_aiplatform" {
  count   = local.v3h_canary_on ? 1 : 0
  project = module.prj_runtime.project_id
  role    = "roles/aiplatform.viewer"
  member  = google_service_account.v3h_canary[0].member
}

output "v3h_canary" {
  description = "v3h canary: email (for --impersonate-service-account), ingress identity string, bucket it lists; null when off."
  value = local.v3h_canary_on ? {
    email    = google_service_account.v3h_canary[0].email
    identity = google_service_account.v3h_canary[0].member
    bucket   = google_storage_bucket.dc3_build[0].name
  } : null
}
