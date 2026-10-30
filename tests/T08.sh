#!/usr/bin/env bash
# shellcheck disable=SC2016
# T08: bucket location restricted to EU by gcp.resourceLocations (stage 1, CMEK policy off).
set -u
source "$(dirname "$0")/lib.sh"
require_config

FOLDER="$(folder_id root)"
PROJ="$(project_id data)"
LZV_SCOPE="folders/$FOLDER"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/resource-manager/docs/organization-policy/defining-locations"
  "https://docs.cloud.google.com/organization-policy/reference/org-policy-constraints"
)

# Stage guard (read-only): restrictNonCmekServices must NOT be set on the folder.
GOUT="$(gcloud org-policies describe gcp.restrictNonCmekServices --folder="$FOLDER" --format=json --billing-project="$(quota_project)" 2>&1 </dev/null)"
GRC=$?
if [[ $GRC -eq 0 ]]; then
  lzv_die "gcp.restrictNonCmekServices is set on the folder: run T08 in stage 1"
elif ! grep -Eqi 'NOT_FOUND|not found' <<<"$GOUT"; then
  lzv_die "cannot read gcp.restrictNonCmekServices on the folder (exit $GRC); stage unknown"
fi

header T08 Baseline \
  '`gcp.resourceLocations` `in:eu-locations` (folder)' \
  'Denied; error contains `violates constraint constraints/gcp.resourceLocations` (attribute by constraint name if T07 is also active)'
note "stage guard ok: gcp.restrictNonCmekServices not set on the folder"

BUCKET="$(lzv_name t08)"
cleanup_trap "if gcloud storage buckets describe gs://$BUCKET >/dev/null 2>&1; then gcloud storage buckets delete gs://$BUCKET; fi; if gcloud storage buckets describe gs://$BUCKET >/dev/null 2>&1; then echo 'CLEANUP CHECK: bucket still exists'; else echo 'CLEANUP CHECK: bucket gone'; fi"

run_capture gcloud storage buckets create "gs://$BUCKET" --location=us-central1 --project="$PROJ"
expect_denied "violates constraint '?constraints/gcp\.resourceLocations'?"
SEEN="$(grep -Eo 'constraints/[A-Za-z.]+' "$LZV_LAST_OUT" | sort -u | tr '\n' ' ')"
note "constraints named in error: ${SEEN:-none}"

write_result "$LZV_VERDICT" Enforced \
  "bucket create in us-central1 exited $LZV_LAST_RC; constraints named: ${SEEN:-none}" \
  "$LZV_REASON"
