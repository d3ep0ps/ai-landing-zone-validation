#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2119
# T20 (v1.1, TS2): gcp.restrictNonCmekServices refuses a non-CMEK bucket; paired CMEK control; attribution from the Policy Denied audit log.
# Needs enable_t07_policy=true and enable_dc3_build_bucket=true (the DC3 key is reused).
set -u
source "$(dirname "$0")/lib.sh"
require_config

FOLDER="$(folder_id root)"
PROJ="$(project_id runtime)"   # the DC3 key lives here; its Cloud Storage service agent already has key access
LZV_SCOPE="folders/$FOLDER"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/kms/docs/cmek-org-policy"
  "https://docs.cloud.google.com/resource-manager/docs/organization-policy/audit-logging"
  "https://docs.cloud.google.com/resource-manager/docs/organization-policy/dry-run-policy"
)

# Guard (read-only): the folder policy must deny storage.googleapis.com (as T07).
POL="$(gcloud org-policies describe gcp.restrictNonCmekServices --folder="$FOLDER" --format=json --billing-project="$(quota_project)" 2>/dev/null </dev/null)"
jq -e '[.spec.rules[]?.values.deniedValues[]?] | any(test("storage\\.googleapis\\.com"))' <<<"$POL" >/dev/null 2>&1 \
  || lzv_die "gcp.restrictNonCmekServices does not deny storage.googleapis.com on the folder: set enable_t07_policy=true and wait 15 min"
DC3_BUCKET="$(lzv_tf '.dc3_build_bucket.value // empty')"
[[ -n "$DC3_BUCKET" ]] || lzv_die "dc3_build_bucket output is empty: set enable_dc3_build_bucket=true"

header T20 Baseline \
  'TS2 for `gcp.restrictNonCmekServices`' \
  'Without CMEK refused (HTTP 412, as in v1 T07); with CMEK created; constraint name recorded from the Policy Denied audit log if present, else stated as attribution by elimination'
note "guard ok: folder policy deniedValues = $(jq -c '[.spec.rules[]?.values.deniedValues[]?]' <<<"$POL"); key source bucket $DC3_BUCKET"

run_capture gcloud storage buckets describe "gs://$DC3_BUCKET" --format='value(default_kms_key)'
KEY="$(tr -d '[:space:]' <"$LZV_LAST_OUT")"
[[ "$LZV_LAST_RC" == 0 && "$KEY" == projects/*/cryptoKeys/* ]] || lzv_die "cannot read the default KMS key of the DC3 bucket"
KEY="${KEY%%/cryptoKeyVersions/*}"

B1="$(lzv_name t20)"
B2="$(lzv_name t20c)"
for B in "$B1" "$B2"; do
  cleanup_trap "if gcloud storage buckets describe gs://$B >/dev/null 2>&1; then gcloud storage buckets delete gs://$B; fi; if gcloud storage buckets describe gs://$B >/dev/null 2>&1; then echo 'CLEANUP CHECK: bucket still exists'; else echo 'CLEANUP CHECK: bucket gone'; fi"
done

# Attempt 1: no CMEK.
T0="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run_capture gcloud storage buckets create "gs://$B1" --location=europe-west1 --project="$PROJ"
expect_denied '412' 'customer-managed encryption key \(CMEK\) on the bucket is required by an org policy'
V1="$LZV_VERDICT"; R1="$LZV_REASON"

# Attempt 2: paired control, same location, with the key.
run_capture gcloud storage buckets create "gs://$B2" --location=europe-west1 --project="$PROJ" --default-encryption-key="$KEY"
expect_success
V2="$LZV_VERDICT"; R2="$LZV_REASON"

# Attribution: Policy Denied audit log (read-only). Entries can lag, so retry a few times.
ATTR="attribution by elimination"
for try in 1 2 3 4 5; do
  run_capture gcloud logging read 'logName:"cloudaudit.googleapis.com%2Fpolicy" AND protoPayload.metadata.constraint:"gcp.restrictNonCmekServices"' \
    --project="$PROJ" --freshness=30m --limit=5 --format=json
  if [[ "$LZV_LAST_RC" == 0 ]] && grep -q 'gcp.restrictNonCmekServices' "$LZV_LAST_OUT"; then
    ATTR="constraint recorded from Policy Denied audit log: constraints/gcp.restrictNonCmekServices"
    break
  fi
  [[ "$try" -lt 5 ]] && sleep 60
done
note "attempt 1 started $T0; $ATTR"

V="$(verdict_merge "$V1" "$V2")"
REASON=""
[[ "$V1" == PASS ]] || REASON+="attempt 1 (no CMEK): $R1; "
[[ "$V2" == PASS ]] || REASON+="attempt 2 (CMEK control): $R2; "
write_result "$V" Enforced \
  "no-CMEK bucket create: $V1; CMEK bucket create: $V2; $ATTR" \
  "$REASON"
