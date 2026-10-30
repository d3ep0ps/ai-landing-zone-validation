#!/usr/bin/env bash
# shellcheck disable=SC2016
# T09: public access prevention blocks allUsers objectViewer (stage 1, CMEK policy off).
set -u
source "$(dirname "$0")/lib.sh"
require_config

FOLDER="$(folder_id root)"
PROJ="$(project_id data)"
LZV_SCOPE="folders/$FOLDER"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/storage/docs/public-access-prevention"
  "https://docs.cloud.google.com/organization-policy/reference/org-policy-constraints"
)

# Stage guard (read-only): restrictNonCmekServices must NOT be set on the folder.
GOUT="$(gcloud org-policies describe gcp.restrictNonCmekServices --folder="$FOLDER" --format=json --billing-project="$(quota_project)" 2>&1 </dev/null)"
GRC=$?
if [[ $GRC -eq 0 ]]; then
  lzv_die "gcp.restrictNonCmekServices is set on the folder: run T09 in stage 1"
elif ! grep -Eqi 'NOT_FOUND|not found' <<<"$GOUT"; then
  lzv_die "cannot read gcp.restrictNonCmekServices on the folder (exit $GRC); stage unknown"
fi

header T09 Baseline \
  '`storage.publicAccessPrevention` (folder)' \
  'Denied; error refers to public access prevention, not Domain Restricted Sharing'
note "stage guard ok: gcp.restrictNonCmekServices not set on the folder"

BUCKET="$(lzv_name t09)"
cleanup_trap "if gcloud storage buckets describe gs://$BUCKET >/dev/null 2>&1; then gcloud storage buckets delete gs://$BUCKET; fi; if gcloud storage buckets describe gs://$BUCKET >/dev/null 2>&1; then echo 'CLEANUP CHECK: bucket still exists'; else echo 'CLEANUP CHECK: bucket gone'; fi"

# Precondition: a plain EU bucket.
if ! run_capture gcloud storage buckets create "gs://$BUCKET" --location=europe-west1 --project="$PROJ"; then
  write_result INCONCLUSIVE Enforced "precondition bucket create failed (exit $LZV_LAST_RC)" \
    "could not create the EU test bucket, so the allUsers grant was not attempted"
  exit 0
fi

run_capture gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" --member=allUsers --role=roles/storage.objectViewer
if [[ "$LZV_LAST_RC" != 0 ]] && last_output_matches 'allowedPolicyMemberDomains' \
   && ! last_output_matches '[Pp]ublic [Aa]ccess [Pp]revention|publicAccessPrevention'; then
  LZV_VERDICT=INCONCLUSIVE
  LZV_REASON="error names iam.allowedPolicyMemberDomains (Domain Restricted Sharing), not public access prevention; cannot attribute the denial"
else
  expect_denied '[Pp]ublic [Aa]ccess [Pp]revention|publicAccessPrevention'
fi
SEEN="$(grep -Eo 'constraints/[A-Za-z.]+|publicAccessPrevention|allowedPolicyMemberDomains' "$LZV_LAST_OUT" | sort -u | tr '\n' ' ')"
note "constraint/terms named in error: ${SEEN:-none}"

write_result "$LZV_VERDICT" Enforced \
  "allUsers objectViewer binding exited $LZV_LAST_RC; terms named: ${SEEN:-none}" \
  "$LZV_REASON"
