#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2119
# T21 (v1.1, DC3): Cloud Build with the CMEK staging bucket succeeds; plain build is refused.
# Needs enable_dc3_build_bucket=true and enable_t07_policy=true.
set -u
source "$(dirname "$0")/lib.sh"
require_config

FOLDER="$(folder_id root)"
PROJ="$(project_id mcp)"
LZV_SCOPE="folders/$FOLDER"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/build/docs/securing-builds/store-manage-build-logs"
  "https://docs.cloud.google.com/kms/docs/cmek-org-policy"
)

POL="$(gcloud org-policies describe gcp.restrictNonCmekServices --folder="$FOLDER" --format=json --billing-project="$(quota_project)" 2>/dev/null </dev/null)"
jq -e '[.spec.rules[]?.values.deniedValues[]?] | any(test("storage\\.googleapis\\.com"))' <<<"$POL" >/dev/null 2>&1 \
  || lzv_die "gcp.restrictNonCmekServices does not deny storage.googleapis.com on the folder: set enable_t07_policy=true and wait 15 min"
BUCKET="$(lzv_tf '.dc3_build_bucket.value // empty')"
[[ -n "$BUCKET" ]] || lzv_die "dc3_build_bucket output is empty: set enable_dc3_build_bucket=true"

header T21 Baseline DC3 \
  'Build with the CMEK staging bucket succeeds; plain build refused (as in v1 T10)'
note "guard ok: folder policy deniedValues = $(jq -c '[.spec.rules[]?.values.deniedValues[]?]' <<<"$POL"); CMEK bucket in use (name recorded in command.txt)"

STAGING="gs://${PROJ}_cloudbuild"
# Precondition: the implicit staging bucket must not exist yet (else the plain build proves nothing).
run_capture gcloud storage buckets describe "$STAGING"
if [[ "$LZV_LAST_RC" == 0 ]]; then
  not_tested Enforced "implicit staging bucket already exists"
elif ! last_output_matches '404|NOT_FOUND|not found|does not exist'; then
  write_result INCONCLUSIVE Enforced "precondition check exited $LZV_LAST_RC without a not-found signature" \
    "could not confirm that the implicit staging bucket is absent"
  exit 0
fi

mkdir -p "$LZV_ROOT/scratch"
PRE="$(mktemp "$LZV_ROOT/scratch/lzv-t21-pre.XXXXXX")"
PREOBJ="$(mktemp "$LZV_ROOT/scratch/lzv-t21-obj.XXXXXX")"
gcloud storage buckets list --project="$PROJ" --format='value(name)' </dev/null 2>/dev/null | grep cloudbuild >"$PRE" || true
gcloud storage ls --recursive "gs://$BUCKET/**" </dev/null 2>/dev/null >"$PREOBJ" || true
cleanup_trap "rm -f $PRE $PREOBJ"
cleanup_trap "for o in \$(gcloud storage ls --recursive 'gs://$BUCKET/**' | grep -vxFf $PREOBJ); do echo \"CLEANUP: deleting new object \$o\"; gcloud storage rm \$o; done; gcloud storage ls --recursive 'gs://$BUCKET/**' | grep -vxFf $PREOBJ && echo 'CLEANUP CHECK: new objects remain' || echo 'CLEANUP CHECK: no new objects'"
cleanup_trap "for b in \$(gcloud storage buckets list --project=$PROJ --format='value(name)' | grep cloudbuild | grep -vxFf $PRE); do echo \"CLEANUP: deleting new bucket \$b\"; gcloud storage rm --recursive gs://\$b; done; gcloud storage buckets list --project=$PROJ --format='value(name)' | grep cloudbuild | grep -vxFf $PRE && echo 'CLEANUP CHECK: new cloudbuild bucket still exists' || echo 'CLEANUP CHECK: no new cloudbuild buckets'"

SRC="$(mktemp -d "$LZV_ROOT/scratch/lzv-t21.XXXXXX")"
cleanup_trap "rm -rf $SRC"
cat >"$SRC/cloudbuild.yaml" <<'YAML'
steps:
  - name: ubuntu
    args: ['echo', 'lzv-t21']
YAML

# Build 1: CMEK staging and log bucket.
run_capture gcloud builds submit "$SRC" --config="$SRC/cloudbuild.yaml" --project="$PROJ" \
  --region=europe-west1 --gcs-source-staging-dir="gs://$BUCKET/source" --gcs-log-dir="gs://$BUCKET/logs"
expect_success
V1="$LZV_VERDICT"; R1="$LZV_REASON"
B1_RC="$LZV_LAST_RC"
note "build 1 (CMEK bucket): exit $B1_RC, verdict $V1"

# Build 2 (control): plain build, as v1 T10 attempt 1. v1 finding: blocked by gcp.resourceLocations or CMEK.
CMEK_RE='gcp\.restrictNonCmekServices|customer-managed encryption key \(CMEK\).*required by an org policy'
run_capture gcloud builds submit "$SRC" --config="$SRC/cloudbuild.yaml" --project="$PROJ" --region=europe-west1
# Only the two refusals seen in v1 T10 count (Opus review 2026-10-25: generic codes would also match unrelated IAM errors).
expect_denied "$CMEK_RE|constraints/gcp\\.resourceLocations"
V2="$LZV_VERDICT"; R2="$LZV_REASON"
BY="other"
last_output_matches 'gcp\.resourceLocations' && BY="gcp.resourceLocations"
last_output_matches "$CMEK_RE" && BY="CMEK"
note "build 2 (plain): exit $LZV_LAST_RC, blocked by: $BY"

V="$(verdict_merge "$V1" "$V2")"
REASON=""
[[ "$V1" == PASS ]] || REASON+="build 1 (CMEK bucket): $R1; "
[[ "$V2" == PASS ]] || REASON+="build 2 (plain): $R2; "
write_result "$V" Enforced \
  "CMEK-bucket build: exit $B1_RC ($V1); plain build: exit $LZV_LAST_RC, blocked by $BY ($V2)" \
  "$REASON"
