# v2 B, run 8 draft: VPC egress for the Agent Gateway, so it can reach the internal-ingress Cloud Run MCP
# fixtures. Default OFF (var.enable_v2_gateway_vpc). Not applied yet.
#
# Why: in run 7 the gateway (no network_config) reached run.app over the internet path; Cloud Run ingress
# "internal" (folder policy run.allowedIngress) answered 404 before the container (results.md Findings 25).
# Source for every setting below: notes/doc-verification-v2-B-netattach.md (accessed 2026-10-30).
#
# Shape (codelab-proven path "a" in the note):
#   gateway --PSC interface--> network attachment (/28, Private Google Access, ACCEPT_AUTOMATIC)
#           --> VPC lzv-gw-vpc --> PSC endpoint for Google APIs (all-apis, private IP)
#   DNS: private zone run.app. on lzv-gw-vpc, *.run.app -> the PSC endpoint IP; the gateway resolves it
#        through network_config.dns_peering_config (domains ["run.app."]).
# Everything is in the runtime project, the same project as the Cloud Run fixtures: Cloud Run counts
# "VPC networks that are in the same project" as internal (ingress doc). That a PSC-interface origin counts
# is INFERRED from the codelab, not stated; run 8 checks it (Cloud Run request log shows the call).
#
# Separate VPC on purpose: the PSC-interface VPC of T33/T34 (module.swp_vpc) needs the paid Secure Web Proxy
# and has a deny-all egress firewall rule that would block this path.
#
# No firewall rules: the doc and codelab need none (implied egress allow; PSC endpoints are not VMs).
#
# Order: the gateway references the attachment and the VPC, so one apply creates them first. networkAttachment
# is immutable on a gateway, so the gateway is created with it from the start (it is created fresh each run).
# Destroy: the attachment can stay "in use" for 5 to 30 minutes after the gateway is deleted (doc); if the
# subnet or attachment delete fails, wait and re-plan (as with the SWP subnet in runs 5 and 7).
#
# The provider bills Cloud DNS calls to the quota (seed) project, so dns.googleapis.com must be on there.
# It is managed below (google_project_service.v2_gw_seed_dns), not gated, so it is in place before the
# first run-8 apply. It was already enabled when added (2026-10-30); the apply only records it in state.

locals {
  gw_vpc_on      = local.gw_on && var.enable_v2_gateway_vpc
  gw_vpc_network = "projects/${local.gw_project}/global/networks/lzv-gw-vpc"
}

resource "google_project_service" "v2_gw_vpc" {
  for_each           = local.gw_vpc_on ? toset(["dns.googleapis.com"]) : toset([])
  project            = local.gw_project
  service            = each.key
  disable_on_destroy = false
}

# Quota project (seed). disable_on_destroy = false: removing this resource never turns the API off. If
# var.quota_project is switched for a stage (e.g. to the data project), the plan shows this entry moving; that
# is expected and harmless.
resource "google_project_service" "v2_gw_seed_dns" {
  project            = var.quota_project
  service            = "dns.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_network" "v2_gw" {
  count                   = local.gw_vpc_on ? 1 : 0
  project                 = local.gw_project
  name                    = "lzv-gw-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  depends_on              = [google_project_service.v2_gw]
}

# Doc: minimum /28, same VPC as the attachment, Private Google Access on.
resource "google_compute_subnetwork" "v2_gw_attach" {
  count                    = local.gw_vpc_on ? 1 : 0
  project                  = local.gw_project
  region                   = var.region
  name                     = "lzv-gw-attach"
  network                  = google_compute_network.v2_gw[0].id
  ip_cidr_range            = var.v2_gateway_vpc_subnet_cidr
  private_ip_google_access = true
}

# Doc: "Configure the network attachment to automatically accept connections".
resource "google_compute_network_attachment" "v2_gw" {
  count                 = local.gw_vpc_on ? 1 : 0
  project               = local.gw_project
  region                = var.region
  name                  = "lzv-gw-attach"
  connection_preference = "ACCEPT_AUTOMATIC"
  subnetworks           = [google_compute_subnetwork.v2_gw_attach[0].self_link]
}

# PSC endpoint for Google APIs (run.app is served by it). The address must be outside every subnet of the VPC.
resource "google_compute_global_address" "v2_gw_psc" {
  count        = local.gw_vpc_on ? 1 : 0
  project      = local.gw_project
  name         = "lzv-gw-psc-apis"
  purpose      = "PRIVATE_SERVICE_CONNECT"
  address_type = "INTERNAL"
  address      = var.v2_gateway_psc_ip
  network      = google_compute_network.v2_gw[0].id
}

# Name rule for Google-APIs endpoints: 1-20 characters, lowercase letters and digits only (codelab: psc2gapis).
resource "google_compute_global_forwarding_rule" "v2_gw_psc" {
  count                 = local.gw_vpc_on ? 1 : 0
  project               = local.gw_project
  name                  = "lzvgwapis"
  target                = "all-apis"
  network               = google_compute_network.v2_gw[0].id
  ip_address            = google_compute_global_address.v2_gw_psc[0].id
  load_balancing_scheme = ""
}

# Private zone run.app. on the gateway VPC only; the gateway reaches it through DNS peering.
resource "google_dns_managed_zone" "v2_gw_runapp" {
  count      = local.gw_vpc_on ? 1 : 0
  project    = local.gw_project
  name       = "lzv-gw-runapp"
  dns_name   = "run.app."
  visibility = "private"
  private_visibility_config {
    networks {
      network_url = google_compute_network.v2_gw[0].id
    }
  }
  depends_on = [google_project_service.v2_gw_vpc, google_project_service.v2_gw_seed_dns]
}

resource "google_dns_record_set" "v2_gw_runapp" {
  count        = local.gw_vpc_on ? 1 : 0
  project      = local.gw_project
  managed_zone = google_dns_managed_zone.v2_gw_runapp[0].name
  name         = "*.run.app."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.v2_gw_psc[0].address]
}
