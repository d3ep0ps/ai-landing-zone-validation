# v1.1 DC2 (T22, T23): perimeter rollout support.
#
# tooling_quota_project: documentation/variable only. It is NOT wired into the provider block,
# because the providers are configured from var.quota_project and a provider cannot depend on a
# resource created in the same apply. Switch by setting quota_project in terraform.tfvars to the
# in-perimeter project ID (after that project exists), or per shell with
#   GOOGLE_BILLING_PROJECT=<id> GOOGLE_USER_PROJECT_OVERRIDE=true terraform ...
# (an explicit billing_project in the provider block wins over the env var, so unset quota_project
# usage first). For gcloud use --billing-project=<id>. See README v1.1.

variable "tooling_quota_project" {
  description = "v1.1 DC2: in-perimeter project ID (e.g. the runtime or data project) to use as Terraform billing_project / gcloud --billing-project during enforcement (T22). Recorded in the tooling_quota_project output only. Default empty."
  type        = string
  default     = ""
}

variable "vpc_sc_agent_ingress_identities" {
  description = "v1.1 DC2/T23: principal:// strings of agents allowed into the perimeter to aiplatform.googleapis.com (runtime project). Empty = no rule. Default empty."
  type        = list(string)
  default     = []
}

locals {
  vpc_sc_agent_ingress_policy = length(var.vpc_sc_agent_ingress_identities) > 0 ? {
    agents = {
      from = {
        access_levels = ["*"]
        identities    = var.vpc_sc_agent_ingress_identities
      }
      to = {
        operations = [
          { service_name = "aiplatform.googleapis.com", method_selectors = ["*"] },
        ]
        resources = ["projects/${module.prj_runtime.number}"]
      }
    }
  } : {}
}

output "tooling_quota_project" {
  description = "DC2: configured in-perimeter tooling quota project (empty when unset)."
  value       = var.tooling_quota_project
}

# The tooling quota project is billed for every API call Terraform and gcloud make
# (user_project_override), so those APIs must be enabled there. Found 2026-10-25 before T22:
# the data project lacked orgpolicy, accesscontextmanager, cloudbilling and containeranalysis.
variable "tooling_quota_services" {
  description = "v1.1 DC2: APIs enabled in tooling_quota_project (only when it is set)."
  type        = list(string)
  default = [
    "accesscontextmanager.googleapis.com",
    "aiplatform.googleapis.com",
    "binaryauthorization.googleapis.com",
    "cloudbilling.googleapis.com",
    "cloudkms.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "containeranalysis.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "orgpolicy.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
  ]
}

resource "google_project_service" "tooling_quota" {
  for_each           = var.tooling_quota_project == "" ? toset([]) : toset(var.tooling_quota_services)
  project            = var.tooling_quota_project
  service            = each.value
  disable_on_destroy = false
}
