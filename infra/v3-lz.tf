# v3: closer to the VALZ GCP reference profile. Every addition is behind a toggle that defaults to
# off/empty, so a plan with the current terraform.tfvars shows no changes. Drafted, never planned.
#   A  extra folder org policies (GOV-02, GOV-06, GOV-07, GOV-09, SUP-01)
#   B  extra VPC-SC restricted services (see vpc-sc.tf)
#   C  per-project Vertex AI budgets (RUN-03 spend-cap signal)
#   D  environment folders with per-environment vertexai.allowedModels

# --- Variables ---------------------------------------------------------------

variable "enable_v3_org_policies" {
  description = "v3 A: extra boolean folder policies on fldr-lz-validation (SA key upload, default SA grants, privileged basic roles on default SAs, uniform bucket-level access, notebook public IP, Cloud Run inlined source). Default off."
  type        = bool
  default     = false
}

variable "enable_v3_cmek_key_projects" {
  description = "v3 A: gcp.restrictCmekCryptoKeyProjects on fldr-lz-validation, allowing keys only in v3_cmek_key_projects. Enable only once all CMEK keys live in the listed projects. Default off."
  type        = bool
  default     = false
  validation {
    condition     = !var.enable_v3_cmek_key_projects || length(var.v3_cmek_key_projects) > 0
    error_message = "enable_v3_cmek_key_projects requires at least one project in v3_cmek_key_projects (an empty allow list would block every CMEK key)."
  }
}

variable "v3_cmek_key_projects" {
  description = "v3 A: projects allowed to hold CMEK keys: project IDs (become under:projects/<id>) or full under:projects/<id> values."
  type        = list(string)
  default     = []
}

variable "v3_operator_ingress_all_restricted" {
  description = "v3 B: make the operator ingress rule cover every restricted service (default list plus v3_extra_restricted_services) instead of only storage and aiplatform. Needed when Terraform manages e.g. Model Armor from the operator identity outside the perimeter. Default off."
  type        = bool
  default     = false
}

variable "v3_extra_restricted_services" {
  description = "v3 B: services appended to vpc_sc_restricted_services (spec and status). Add only services confirmed as VPC-SC supported (gcloud access-context-manager supported-services describe). Default none."
  type        = list(string)
  default     = []
}

variable "enable_v3_budgets" {
  description = "v3 C: one Vertex AI budget per project (runtime, mcp, data) on var.billing_account. Needs v3_vertex_billing_service_id and billingbudgets.googleapis.com on the quota project. Default off."
  type        = bool
  default     = false
  validation {
    condition     = !var.enable_v3_budgets || var.v3_vertex_billing_service_id != null
    error_message = "enable_v3_budgets requires v3_vertex_billing_service_id."
  }
}

variable "v3_budget_amount_usd" {
  description = "v3 C: budget amount per project in whole USD. A budget alerts; it does not cap spend."
  type        = number
  default     = 10
}

variable "v3_vertex_billing_service_id" {
  description = "v3 C: Cloud Billing service ID of Vertex AI, the part after services/ in the budget filter. Public catalog value (Cloud Billing Catalog API services.list, notes/doc-verification.md \"v3\")."
  type        = string
  default     = "C7E2-9256-1C43"
}

variable "enable_v3_env_folders" {
  description = "v3 D: folders fldr-ai-sandbox, fldr-ai-dev, fldr-ai-staging under fldr-lz-validation (sibling of fldr-ai-prod), each with vertexai.allowedModels from v3_env_allowed_models. Folders only, no projects. Default off."
  type        = bool
  default     = false
}

variable "v3_env_allowed_models" {
  description = "v3 D: vertexai.allowedModels per environment; keys sandbox, dev, staging. A missing key means no policy on that folder. Entries need the :predict suffix."
  type        = map(list(string))
  default     = {}
  validation {
    condition     = alltrue([for k in keys(var.v3_env_allowed_models) : contains(["sandbox", "dev", "staging"], k)])
    error_message = "v3_env_allowed_models keys must be sandbox, dev or staging."
  }
}

# --- A: folder org policies ---------------------------------------------------

locals {
  # All six are boolean constraints (enforce = true). All constraint names were confirmed to exist on the
  # folder by a live read-only check (notes/doc-verification.md "v3", 2026-11-03). Boolean form follows the
  # Fabric FAST hardened dataset (vendor/fabric/fast/stages/0-org-setup/datasets/hardened/organization/org-policies/*.yaml).
  org_policies_v3 = merge(
    var.enable_v3_org_policies ? {
      # GOV-02. FAST uses the legacy iam.disableServiceAccountKeyUpload; the managed one is used here (T01 style).
      "iam.managed.disableServiceAccountKeyUpload" = { rules = [{ enforce = true }] }
      # GOV-09 (boolean in FAST compute.yaml)
      "iam.automaticIamGrantsForDefaultServiceAccounts" = { rules = [{ enforce = true }] }
      # GOV-09 (managed, boolean in FAST iam.yaml)
      "iam.managed.preventPrivilegedBasicRolesForDefaultServiceAccounts" = { rules = [{ enforce = true }] }
      # GOV-07 (boolean in FAST storage.yaml)
      "storage.uniformBucketLevelAccess" = { rules = [{ enforce = true }] }
      # GOV-07 (boolean in FAST); legacy-named, notebooks product constraint
      "ainotebooks.restrictPublicIp" = { rules = [{ enforce = true }] }
      # SUP-01
      "run.managed.disableInlinedSource" = { rules = [{ enforce = true }] }
    } : {},
    # GOV-06 companion to T07. List constraint; the value prefix under: is the documented form for
    # resource hierarchy values. Enable only once all CMEK keys live in the listed projects: existing
    # keys elsewhere would block new CMEK-protected resources. Not retroactive.
    var.enable_v3_cmek_key_projects ? {
      "gcp.restrictCmekCryptoKeyProjects" = {
        # Entries may be plain project IDs or already in under:projects/<id> form.
        rules = [{ allow = { values = [for p in var.v3_cmek_key_projects : startswith(p, "under:") ? p : "under:projects/${p}"] } }]
      }
    } : {},
  )
}

# --- C: budgets (RUN-03) ------------------------------------------------------

locals {
  v3_budget_projects = var.enable_v3_budgets ? {
    runtime = module.prj_runtime.number
    mcp     = module.prj_mcp.number
    data    = module.prj_data.number
  } : {}
}

# A budget sends alerts to the default billing-account email recipients; it does NOT cap spend or
# stop usage. It is a spend-cap signal only. No Pub/Sub topic, so nothing can act on it automatically.
resource "google_billing_budget" "v3_vertex" {
  for_each        = local.v3_budget_projects
  billing_account = var.billing_account
  display_name    = "lzv-v3-vertex-${each.key}"

  budget_filter {
    projects               = ["projects/${each.value}"]
    services               = ["services/${var.v3_vertex_billing_service_id}"]
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(floor(var.v3_budget_amount_usd))
    }
  }

  dynamic "threshold_rules" {
    for_each = [0.5, 0.9, 1.0]
    content {
      threshold_percent = threshold_rules.value
      spend_basis       = "CURRENT_SPEND"
    }
  }
}

# --- D: environment folders ---------------------------------------------------

locals {
  v3_env_folders = var.enable_v3_env_folders ? {
    sandbox = "fldr-ai-sandbox"
    dev     = "fldr-ai-dev"
    staging = "fldr-ai-staging"
  } : {}
}

module "v3_env_folder" {
  source   = "../vendor/fabric/modules/folder"
  for_each = local.v3_env_folders
  parent   = module.folder_root.id
  name     = each.value
  org_policies = contains(keys(var.v3_env_allowed_models), each.key) ? {
    "vertexai.allowedModels" = { rules = [{ allow = { values = var.v3_env_allowed_models[each.key] } }] }
  } : {}
}

# --- E: network in the existing runtime project (NET-03 partial: no proxy, no NAT) ---------------

variable "enable_v3_net" {
  description = "v3 E: VPC lzv-net-vpc with one subnet, restricted.googleapis.com DNS and route, egress deny-all firewall, all in the runtime project. No new projects. Default off."
  type        = bool
  default     = false
}

variable "v3_net_workload_cidr" {
  description = "v3 E: CIDR of subnet lzv-net-workload (must not overlap 10.77.x used by SWP, PSC-I and the gateway VPC)."
  type        = string
  default     = "10.78.0.0/24"
}

variable "v3_net_allow_iap_ssh" {
  description = "v3 E: allow ingress tcp:22 from the IAP range 35.235.240.0/20. Default off; no other ingress allow exists."
  type        = bool
  default     = false
}

locals {
  # compute.googleapis.com is enabled by google_project_service.swp when swp_enabled; reuse that, do not duplicate.
  # dns.googleapis.com may also be enabled by v2-gateway-vpc.tf when the gateway VPC is on; enabling twice is idempotent.
  v3_net_services = var.enable_v3_net ? toset(concat(
    ["dns.googleapis.com"],
    var.swp_enabled ? [] : ["compute.googleapis.com"],
  )) : toset([])
}

resource "google_project_service" "v3_net" {
  for_each           = local.v3_net_services
  project            = module.prj_runtime.project_id
  service            = each.key
  disable_on_destroy = false
}

module "v3_net_vpc" {
  count                           = var.enable_v3_net ? 1 : 0
  source                          = "../vendor/fabric/modules/net-vpc"
  project_id                      = module.prj_runtime.project_id
  name                            = "lzv-net-vpc"
  routing_mode                    = "REGIONAL"
  auto_create_subnetworks         = false
  delete_default_routes_on_create = true # no 0.0.0.0/0 internet route; only the restricted VIP route below
  # Only the restricted.googleapis.com route (199.36.153.4/30 -> default internet gateway) is created.
  create_googleapis_routes = {
    directpath = false
    private    = false
    restricted = true
  }
  subnets = [{
    name                  = "lzv-net-workload"
    region                = var.region
    ip_cidr_range         = var.v3_net_workload_cidr
    enable_private_access = true
  }]
  depends_on = [google_project_service.v3_net]
}

module "v3_net_firewall" {
  count      = var.enable_v3_net ? 1 : 0
  source     = "../vendor/fabric/modules/net-vpc-firewall"
  project_id = module.prj_runtime.project_id
  network    = module.v3_net_vpc[0].name

  default_rules_config = { disabled = true }

  egress_rules = {
    lzv-net-allow-egress-restricted-vip = {
      deny               = false
      description        = "v3 E: tcp:443 to restricted.googleapis.com only."
      priority           = 1000
      destination_ranges = ["199.36.153.4/30"]
      rules              = [{ protocol = "tcp", ports = ["443"] }]
    }
    lzv-net-deny-egress-all = {
      deny               = true
      description        = "v3 E: deny all other egress."
      priority           = 65000
      destination_ranges = ["0.0.0.0/0"]
      enable_logging     = { include_metadata = true }
    }
  }

  ingress_rules = var.v3_net_allow_iap_ssh ? {
    lzv-net-allow-ingress-iap-ssh = {
      description   = "v3 E: IAP TCP forwarding to ssh."
      priority      = 1000
      source_ranges = ["35.235.240.0/20"]
      rules         = [{ protocol = "tcp", ports = ["22"] }]
    }
  } : {}
}

# Private zone googleapis.com. -> restricted VIP. Cloud DNS private zone costs about USD 0.20/month
# (plus negligible query charges).
module "v3_net_dns" {
  count      = var.enable_v3_net ? 1 : 0
  source     = "../vendor/fabric/modules/dns"
  project_id = module.prj_runtime.project_id
  name       = "lzv-net-googleapis"
  zone_config = {
    domain = "googleapis.com."
    private = {
      client_networks = [module.v3_net_vpc[0].id]
    }
  }
  recordsets = {
    "A restricted" = { ttl = 300, records = ["199.36.153.4", "199.36.153.5", "199.36.153.6", "199.36.153.7"] }
    "CNAME *"      = { ttl = 300, records = ["restricted.googleapis.com."] }
  }
  depends_on = [google_project_service.v3_net]
}

# --- Outputs ------------------------------------------------------------------

output "v3_budget_ids" {
  value = var.enable_v3_budgets ? { for k, b in google_billing_budget.v3_vertex : k => b.id } : null
}

output "v3_env_folder_ids" {
  value = var.enable_v3_env_folders ? { for k, f in module.v3_env_folder : k => f.id } : null
}

output "v3_org_policy_names" {
  value = length(local.org_policies_v3) > 0 ? sort(keys(local.org_policies_v3)) : null
}

output "v3_net_self_link" {
  value = var.enable_v3_net ? module.v3_net_vpc[0].self_link : null
}

output "v3_net_subnet_name" {
  value = var.enable_v3_net ? "lzv-net-workload" : null
}
