# v1.1 T16 (DC5): Secure Web Proxy (explicit proxy) plus egress firewall for a
# Cloud Run job with Direct VPC egress.
#
# COST: the gateway is paid (about USD 1.25 per gateway-hour plus USD 0.018/GB).
# Everything here is behind var.swp_enabled (default false). Enable it, run the
# test, then destroy the same day:
#   terraform apply -var swp_enabled=true      # human-run, not by agents
#   terraform apply -var swp_enabled=false     # same day; removes gateway, then the rest
# The gateway also creates an auto-generated Cloud Router (swg-autogen-router-*);
# the Fabric module deletes it on destroy (delete_router_on_destroy = true).
#
# Placement: runtime project (module.prj_runtime). It already has run.googleapis.com
# and is the project whose workloads DC5 constrains; no new project (billing limit).
# No Cloud NAT is created: the gateway egresses by itself (its own autogen router).
# The Cloud Run job is created by tests/T16.sh, not by Terraform.

variable "swp_enabled" {
  description = "T16: create the VPC, Secure Web Proxy and egress firewall in the runtime project. Paid (about USD 1.25/gateway-hour); destroy the same day."
  type        = bool
  default     = false
}

variable "swp_allowed_host" {
  description = "Single host allowed through the proxy (session matcher host() == ...)."
  type        = string
  default     = "example.com"
}

variable "swp_port" {
  description = "Gateway listening port (quickstart default 443)."
  type        = number
  default     = 443
}

variable "swp_job_subnet_cidr" {
  description = "Regular subnet for the Cloud Run job (Direct VPC egress) and the gateway address."
  type        = string
  default     = "10.77.0.0/24"
}

variable "swp_proxy_only_cidr" {
  description = "Proxy-only subnet (REGIONAL_MANAGED_PROXY); /23 recommended by docs."
  type        = string
  default     = "10.77.2.0/23"
}

variable "swp_gateway_address" {
  description = "Internal IP of the gateway; must lie inside swp_job_subnet_cidr."
  type        = string
  default     = "10.77.0.10"
}

variable "swp_certificate_url" {
  description = "Certificate Manager certificate for the gateway, regional, in the gateway region: projects/PROJECT/locations/REGION/certificates/NAME. A self-signed one is enough (no TLS inspection). Optional (API reference: certificateUrls is 'Optional'; notes/doc-verification.md, section T16 certificate). Leave null; set only if the first apply rejects a gateway without one (fallback: self-signed regional Certificate Manager certificate)."
  type        = string
  default     = null
}

locals {
  swp_name = "lzv-swp"
  # v2 C (T33/T34): PSC interface attachment subnet; see v2-psci.tf.
  psci_on            = var.swp_enabled && var.enable_v2_psci
  psci_source_ranges = local.psci_on ? [var.v2_psci_subnet_cidr] : []
  swp_services = var.swp_enabled ? toset([
    "compute.googleapis.com",
    "networkservices.googleapis.com",
    "networksecurity.googleapis.com",
    "certificatemanager.googleapis.com",
  ]) : toset([])
}

# prj_runtime lacks these APIs (it has run, but not compute/network*/certificatemanager).
# Added outside the project module so the module's authoritative services list stays
# untouched; disable_on_destroy = false so the destroy leaves the APIs on (harmless, free).
resource "google_project_service" "swp" {
  for_each           = local.swp_services
  project            = module.prj_runtime.project_id
  service            = each.key
  disable_on_destroy = false
}

module "swp_vpc" {
  count        = var.swp_enabled ? 1 : 0
  source       = "../vendor/fabric/modules/net-vpc"
  project_id   = module.prj_runtime.project_id
  name         = "lzv-swp-vpc"
  routing_mode = "REGIONAL"
  subnets = concat([{
    name                  = "lzv-swp-job"
    region                = var.region
    ip_cidr_range         = var.swp_job_subnet_cidr
    enable_private_access = true # Private Google Access on; no firewall allow to Google APIs (see below)
    }],
    # v2 C: /28 attachment subnet for the Agent Runtime PSC interface
    local.psci_on ? [{
      name          = "lzv-swp-psci"
      region        = var.region
      ip_cidr_range = var.v2_psci_subnet_cidr
  }] : [])
  network_attachments = local.psci_on ? {
    lzv-psci = {
      subnet               = "${var.region}/lzv-swp-psci"
      automatic_connection = true # ACCEPT_AUTOMATIC
      description          = "v2 C: Agent Runtime PSC interface (T33, T34)."
    }
  } : {}
  subnets_proxy_only = [{
    name          = "lzv-swp-proxy-only"
    region        = var.region
    ip_cidr_range = var.swp_proxy_only_cidr
    active        = true
  }]
  depends_on = [google_project_service.swp]
}

# Firewall. Priority 1000 allows to the proxy; 65000 denies the rest of egress.
# No allow to Google APIs: the test job only fetches external hosts through the proxy,
# and image pull/logging for Cloud Run are platform-side. A job that needs Google APIs
# with --vpc-egress=all-traffic would need an extra allow (199.36.153.8/30).
# Rules apply to the whole VPC (no tags), so no --network-tags is needed on the job.
module "swp_firewall" {
  count      = var.swp_enabled ? 1 : 0
  source     = "../vendor/fabric/modules/net-vpc-firewall"
  project_id = module.prj_runtime.project_id
  network    = module.swp_vpc[0].name

  default_rules_config = { disabled = true }

  egress_rules = {
    lzv-swp-allow-egress-proxy = {
      deny               = false
      description        = "T16: job subnet to the gateway address and proxy-only subnet on the proxy port."
      priority           = 1000
      source_ranges      = concat([var.swp_job_subnet_cidr], local.psci_source_ranges)
      destination_ranges = ["${var.swp_gateway_address}/32", var.swp_proxy_only_cidr]
      rules              = [{ protocol = "tcp", ports = [tostring(var.swp_port)] }]
    }
    lzv-swp-deny-egress-all = {
      deny = true
      # No source_ranges: applies to every source in the VPC, including the v2 C attachment subnet
      # (T34 expects its direct fetch to hit this rule in the firewall log).
      description        = "T16: deny all other egress (bypass of the proxy must time out)."
      priority           = 65000
      destination_ranges = ["0.0.0.0/0"]
      enable_logging     = { include_metadata = true }
    }
  }

  # Precaution so the first run cannot fail on a missing ingress path to the gateway.
  ingress_rules = {
    lzv-swp-allow-ingress-proxy = {
      description        = "T16: job subnet to the gateway on the proxy port."
      priority           = 1000
      source_ranges      = concat([var.swp_job_subnet_cidr], local.psci_source_ranges)
      destination_ranges = ["${var.swp_gateway_address}/32"]
      rules              = [{ protocol = "tcp", ports = [tostring(var.swp_port)] }]
    }
  }
}

# Gateway in explicit proxy mode (module leaves routing_mode unset = EXPLICIT_ROUTING_MODE,
# only next_hop_routing_mode = true would change it). Request logs (gateway_requests)
# are written by the service by default; no extra switch.
module "swp" {
  count        = var.swp_enabled ? 1 : 0
  source       = "../vendor/fabric/modules/net-swp"
  project_id   = module.prj_runtime.project_id
  region       = var.region
  name         = local.swp_name
  network      = module.swp_vpc[0].id
  subnetwork   = module.swp_vpc[0].subnet_ids["${var.region}/lzv-swp-job"]
  certificates = var.swp_certificate_url == null ? [] : [var.swp_certificate_url]

  gateway_config = {
    addresses = [var.swp_gateway_address]
    ports     = [tostring(var.swp_port)]
  }

  # Anything not matched is denied by the gateway (default_denied).
  policy_rules = {
    allow-single-host = {
      priority        = 1000
      allow           = true
      description     = "T16: the only allowed host."
      session_matcher = "host() == '${var.swp_allowed_host}'"
    }
  }

  depends_on = [module.swp_firewall]
}

output "swp_vpc_name" {
  description = "T16: VPC name (gcloud run jobs create --network)."
  value       = var.swp_enabled ? module.swp_vpc[0].name : null
}

output "swp_job_subnet_name" {
  description = "T16: job subnet name (gcloud run jobs create --subnet, with --vpc-egress=all-traffic)."
  value       = var.swp_enabled ? "lzv-swp-job" : null
  # Depends on the SWP modules so a plan targeted at them also sets this output (stage 11, 2026-10-26).
  depends_on = [module.swp_vpc, module.swp]
}

output "swp_gateway_name" {
  description = "T16: gateway name (also the gateway security policy name)."
  value       = var.swp_enabled ? local.swp_name : null
  # Depends on the SWP modules so a plan targeted at them also sets this output (stage 11, 2026-10-26).
  depends_on = [module.swp_vpc, module.swp]
}

output "swp_policy_id" {
  description = "T16: gateway security policy resource ID."
  value       = var.swp_enabled ? module.swp[0].gateway_security_policy : null
}

output "swp_proxy_url" {
  description = "T16: value for HTTPS_PROXY in the job."
  value       = var.swp_enabled ? "http://${var.swp_gateway_address}:${var.swp_port}" : null
  # Depends on the SWP modules so a plan targeted at them also sets this output (stage 11, 2026-10-26).
  depends_on = [module.swp_vpc, module.swp]
}
