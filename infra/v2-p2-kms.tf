# v2 P2: the key rings lzv-build-keyring (runtime project, europe-west1) and lzv-binauthz-keyring
# (mcp project, var.region) exist in GCP but not in state; key rings and keys cannot be deleted.
# Both keys were left with every version destroyed (Terraform "destroys" a google_kms_crypto_key by
# destroying its versions).
#
# Observed 2026-10-27 (read-only `gcloud kms keys versions list` and a plan): each key has exactly one
# version, number 1, in DESTROY_SCHEDULED (destroy time 2026-11-26). For the symmetric DC3 key the
# primary still points at that version.
#
# Path A (preferred while the version is only scheduled, i.e. before 2026-11-26): the human restores
#   and enables version 1 with gcloud (commands in README "v2 P2"), then sets
#   p2_import_existing_kms = true and leaves p2_create_key_versions = false. T25's data source keeps
#   reading version 1; the DC3 key keeps its primary.
# Path B (after the destroy time, or if the restore fails): p2_create_key_versions = true creates a
#   new version per key. A new version does not replace a destroyed primary on the symmetric key, so
#   the human sets the new version as primary with gcloud before the bucket is created (two applies).
#
# Import: `for_each` on the import blocks is the gate (import blocks cannot use count; the module
# addresses [0] only exist while the dc3/t25 toggle is on).
# What the plan shows: see README "v2 P2".

locals {
  p2_dc3 = var.p2_import_existing_kms && var.enable_dc3_build_bucket
  p2_t25 = var.p2_import_existing_kms && var.enable_t25_binauthz

  p2_dc3_ring_id = "projects/${module.prj_runtime.project_id}/locations/${local.dc3_location}/keyRings/lzv-build-keyring"
  p2_t25_ring_id = "projects/${module.prj_mcp.project_id}/locations/${var.region}/keyRings/lzv-binauthz-keyring"
}

import {
  for_each = local.p2_dc3 ? toset(["ring"]) : toset([])
  to       = module.dc3_kms[0].google_kms_key_ring.default[0]
  id       = local.p2_dc3_ring_id
}

import {
  for_each = local.p2_dc3 ? toset(["lzv-build-key"]) : toset([])
  to       = module.dc3_kms[0].google_kms_crypto_key.default[each.key]
  id       = "${local.p2_dc3_ring_id}/cryptoKeys/${each.key}"
}

import {
  for_each = local.p2_t25 ? toset(["ring"]) : toset([])
  to       = module.t25_kms[0].google_kms_key_ring.default[0]
  id       = local.p2_t25_ring_id
}

import {
  for_each = local.p2_t25 ? toset(["lzv-attestor-key"]) : toset([])
  to       = module.t25_kms[0].google_kms_crypto_key.default[each.key]
  id       = "${local.p2_t25_ring_id}/cryptoKeys/${each.key}"
}

# New versions. destroy_scheduled_duration of the key (default 30 days) applies when these are
# destroyed: the versions stay "scheduled for destruction" after teardown, as before.
resource "google_kms_crypto_key_version" "dc3" {
  count      = var.p2_create_key_versions && var.enable_dc3_build_bucket ? 1 : 0
  crypto_key = module.dc3_kms[0].keys["lzv-build-key"].id
}

resource "google_kms_crypto_key_version" "t25" {
  count      = var.p2_create_key_versions && var.enable_t25_binauthz ? 1 : 0
  crypto_key = module.t25_kms[0].keys["lzv-attestor-key"].id
}
