#!/usr/bin/env bash
# shellcheck disable=SC2016
# T10: gcp.restrictNonCmekServices blocks Cloud Build's implicit staging bucket (stage 2).
set -u
source "$(dirname "$0")/lib.sh"
require_config

FOLDER="$(folder_id root)"
PROJ="$(project_id mcp)"
LZV_SCOPE="folders/$FOLDER"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/kms/docs/cmek-org-policy"
  "https://docs.cloud.google.com/storage/docs/org-policy-constraints"
)

# Stage guard (read-only): the folder policy must deny storage.googleapis.com.
POL="$(gcloud org-policies describe gcp.restrictNonCmekServices --folder="$FOLDER" --format=json --billing-project="$(quota_project)" 2>/dev/null </dev/null)"
jq -e '[.spec.rules[]?.values.deniedValues[]?] | any(test("storage\\.googleapis\\.com"))' <<<"$POL" >/dev/null 2>&1 \
  || lzv_die "gcp.restrictNonCmekServices does not deny storage.googleapis.com on the folder: run T10 in stage 2"

header T10 Baseline \
  '`gcp.restrictNonCmekServices` side effect' \
  'Fails; record exact error (proves article trap #4)'
note "stage guard ok: folder policy deniedValues = $(jq -c '[.spec.rules[]?.values.deniedValues[]?]' <<<"$POL")"

STAGING="gs://${PROJ}_cloudbuild"
run_capture gcloud version

# Precondition: the implicit staging bucket must not exist yet.
run_capture gcloud storage buckets describe "$STAGING"
if [[ "$LZV_LAST_RC" == 0 ]]; then
  not_tested Enforced "staging bucket already exists"
elif ! last_output_matches '404|NOT_FOUND|not found|does not exist'; then
  write_result INCONCLUSIVE Enforced "precondition check exited $LZV_LAST_RC without a not-found signature" \
    "could not confirm that the staging bucket is absent"
  exit 0
fi
note "precondition ok: $STAGING does not exist"

# Clean up only cloudbuild buckets that did not exist before this run.
PRE="$(mktemp "$LZV_ROOT/scratch/lzv-t10-pre.XXXXXX")"
gcloud storage buckets list --project="$PROJ" --format='value(name)' </dev/null 2>/dev/null | grep cloudbuild >"$PRE" || true
note "cloudbuild buckets before: $(wc -l <"$PRE" | tr -d ' ')"
cleanup_trap "rm -f $PRE"
cleanup_trap "for b in \$(gcloud storage buckets list --project=$PROJ --format='value(name)' | grep cloudbuild | grep -vxFf $PRE); do echo \"CLEANUP: deleting new bucket \$b\"; gcloud storage rm --recursive gs://\$b; done; gcloud storage buckets list --project=$PROJ --format='value(name)' | grep cloudbuild | grep -vxFf $PRE && echo 'CLEANUP CHECK: new cloudbuild bucket still exists' || echo 'CLEANUP CHECK: no new cloudbuild buckets'"

mkdir -p "$LZV_ROOT/scratch"
SRC="$(mktemp -d "$LZV_ROOT/scratch/lzv-t10.XXXXXX")"
cleanup_trap "rm -rf $SRC"
cat >"$SRC/cloudbuild.yaml" <<'YAML'
steps:
  - name: ubuntu
    args: ['echo', 'lzv-t10']
YAML

CMEK_RE='gcp\.restrictNonCmekServices|customer-managed encryption key \(CMEK\).*required by an org policy'

# Attempt 1 (recorded, no verdict): default staging bucket. Run 1 finding: created in 'us',
# so gcp.resourceLocations blocks it before CMEK is evaluated.
run_capture gcloud builds submit "$SRC" --config="$SRC/cloudbuild.yaml" --project="$PROJ" --region=europe-west1
A1_RC="$LZV_LAST_RC"
A1_BY="other"
last_output_matches 'gcp\.resourceLocations' && A1_BY="gcp.resourceLocations"
last_output_matches "$CMEK_RE" && A1_BY="CMEK"
note "attempt 1 (default bucket): exit $A1_RC, blocked by: $A1_BY"

# Attempt 2 (verdict): regional user-owned staging bucket in europe-west1, so only the CMEK
# policy can block it (added 2026-10-23 after run 1, human approved).
run_capture gcloud builds submit "$SRC" --config="$SRC/cloudbuild.yaml" --project="$PROJ" --region=europe-west1 --default-buckets-behavior=regional-user-owned-bucket
expect_denied "$CMEK_RE"
BUCKETS="$(grep -Eo 'gs://[^ ]*|[a-z0-9_-]*cloudbuild[^ ]*' "$LZV_LAST_OUT" | sort -u | head -5 | tr '\n' ' ')"
note "attempt 2 (regional bucket): bucket named in error: ${BUCKETS:-none}"

write_result "$LZV_VERDICT" Enforced \
  "default bucket: exit $A1_RC, blocked by $A1_BY; regional bucket: exit $LZV_LAST_RC, CMEK signature $( [[ $LZV_VERDICT == PASS ]] && echo matched || echo not matched)" \
  "$LZV_REASON"
