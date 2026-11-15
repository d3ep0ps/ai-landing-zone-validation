#!/usr/bin/env bash
# shellcheck disable=SC2016
# T07: non-CMEK Cloud Storage bucket blocked by gcp.restrictNonCmekServices (stage 2).
set -u
source "$(dirname "$0")/lib.sh"
require_config

FOLDER="$(folder_id root)"
PROJ="$(project_id data)"
LZV_SCOPE="folders/$FOLDER"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/kms/docs/cmek-org-policy"
  "https://docs.cloud.google.com/organization-policy/reference/org-policy-constraints"
)

# Stage guard (read-only): the folder policy must deny storage.googleapis.com.
POL="$(gcloud org-policies describe gcp.restrictNonCmekServices --folder="$FOLDER" --format=json --billing-project="$(quota_project)" 2>/dev/null </dev/null)"
jq -e '[.spec.rules[]?.values.deniedValues[]?] | any(test("storage\\.googleapis\\.com"))' <<<"$POL" >/dev/null 2>&1 \
  || lzv_die "gcp.restrictNonCmekServices does not deny storage.googleapis.com on the folder: run T07 in stage 2"

header T07 Baseline \
  '`gcp.restrictNonCmekServices` deny `storage.googleapis.com` (folder)' \
  'Denied with HTTP 412 "A default customer-managed encryption key (CMEK) on the bucket is required by an org policy in effect" (changed 2026-10-23 after run 1, human approved: Cloud Storage error and audit log do not name the constraint; attribution by elimination, see results)'
note "stage guard ok: folder policy deniedValues = $(jq -c '[.spec.rules[]?.values.deniedValues[]?]' <<<"$POL")"

BUCKET="$(lzv_name t07)"
cleanup_trap "if gcloud storage buckets describe gs://$BUCKET >/dev/null 2>&1; then gcloud storage buckets delete gs://$BUCKET; fi; if gcloud storage buckets describe gs://$BUCKET >/dev/null 2>&1; then echo 'CLEANUP CHECK: bucket still exists'; else echo 'CLEANUP CHECK: bucket gone'; fi"

run_capture gcloud storage buckets create "gs://$BUCKET" --location=europe-west1 --project="$PROJ"
expect_denied '412' 'customer-managed encryption key \(CMEK\) on the bucket is required by an org policy'
note "attribution: gcp.restrictNonCmekServices is the only CMEK policy on the folder; Cloud Storage does not name the constraint (run 1 finding)"
SEEN="$(grep -Eo 'constraints/[A-Za-z.]+' "$LZV_LAST_OUT" | sort -u | tr '\n' ' ')"
note "constraints named in error: ${SEEN:-none}"

write_result "$LZV_VERDICT" Enforced \
  "bucket create without CMEK in europe-west1 exited $LZV_LAST_RC; constraints named: ${SEEN:-none}" \
  "$LZV_REASON"
