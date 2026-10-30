#!/usr/bin/env bash
# T25: Binary Authorization image admission on Cloud Run (project policy REQUIRE_ATTESTATION).
# Needs terraform enable_t25_binauthz=true and enable_dc3_build_bucket=true (the CMEK build bucket is
# the staging/log bucket for the image build, see T21 and notes/doc-verification.md v1.1 T21/T25).
# NOTE: while enable_t25_binauthz is on, the mcp project's default admission rule is
# REQUIRE_ATTESTATION, so T17's positive control (deploy with --binary-authorization=default of the
# public hello image) is REFUSED. Run T17 with the toggle off; run T25 with it on.
# Cost: cents; the KMS key ring and key cannot be deleted. Signing uses `gcloud beta` (sign-and-create
# is not in the GA group; the track used is recorded in command.txt).
# shellcheck disable=SC2016,SC2119
set -u
source "$(dirname "$0")/lib.sh"
require_config

PROJ="$(project_id mcp)"
LZV_SCOPE="projects/$PROJ"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/binary-authorization/docs/run/configure-policy-cloud-run"
  "https://docs.cloud.google.com/binary-authorization/docs/run/enabling-binauthz-cloud-run"
  "https://docs.cloud.google.com/binary-authorization/docs/making-attestations"
  "https://docs.cloud.google.com/binary-authorization/docs/creating-attestors-cli"
)
header T25 P3 "Binary Authorization image admission" \
  'Unattested image refused ("Service update rejected by Binary Authorization policy" or "is not authorized by policy"); attested image deployed. Signing uses `gcloud beta`; the note is created via REST'

json_last() { sed -n '/^[[{]/,$p' "$LZV_LAST_OUT"; }

# --- Inputs from terraform (null output = toggle off -> lib aborts) ---
KEYVER="$(lzv_tf '.t25_key_version_id.value')"
KEYVER="${KEYVER#//cloudkms.googleapis.com/v1/}"
ATTESTOR="$(lzv_tf '.t25_attestor_name.value')"; ATTESTOR="${ATTESTOR##*/}"
BUCKET="$(lzv_tf '.dc3_build_bucket.value')"
[[ "$KEYVER" == projects/*/cryptoKeyVersions/* ]] || guard_abort "t25_key_version_id has an unexpected shape"

# --- Guard: the project policy requires attestation ---
run_capture gcloud container binauthz policy export --project="$PROJ"
last_output_matches 'REQUIRE_ATTESTATION' || guard_abort "project Binary Authorization policy is not REQUIRE_ATTESTATION; apply with enable_t25_binauthz=true"
note "guard ok: policy contains REQUIRE_ATTESTATION; attestor=$ATTESTOR"

REPO="$(lzv_name t25)"
SVC="$(lzv_name t25)"
IMGPATH="$LZV_REGION-docker.pkg.dev/$PROJ/$REPO/lzv-t25"

# Cleanup, registered before creating (LIFO; each describe is registered first so it runs after its delete).
# The repository delete removes anything left in it; the image delete is explicit as well.
cleanup_trap "gcloud artifacts repositories describe $REPO --location=$LZV_REGION --project=$PROJ --format='value(name)'"
# The repository delete prompts and cannot be confirmed without a terminal; --quiet is not allowed here,
# so it is a human step (run-4 left the repository; Opus review 2026-10-25, before run-5).
cleanup_trap "echo \"HUMAN CLEANUP: gcloud artifacts repositories delete $REPO --location=$LZV_REGION --project=$PROJ\""
# Build source and log objects in the CMEK bucket (run-4 left two; added before run-5, as in T21).
PREOBJ="$(mktemp "$LZV_ROOT/scratch/lzv-t25-obj.XXXXXX")"
gcloud storage ls --recursive "gs://$BUCKET/**" </dev/null 2>/dev/null >"$PREOBJ" || true
cleanup_trap "rm -f $PREOBJ"
cleanup_trap "for o in \$(gcloud storage ls --recursive 'gs://$BUCKET/**' | grep -vxFf $PREOBJ); do echo \"CLEANUP: deleting new object \$o\"; gcloud storage rm \$o; done; gcloud storage ls --recursive 'gs://$BUCKET/**' | grep -vxFf $PREOBJ || echo 'CLEANUP CHECK: no new objects'"
cleanup_run_service "$SVC" "$PROJ"

# --- Build a small image into a project repository (CMEK staging bucket, regional build) ---
run_capture gcloud artifacts repositories create "$REPO" --repository-format=docker --location="$LZV_REGION" --project="$PROJ" --description="lzv t25 temporary"
V_REPO="$LZV_LAST_RC"
run_capture gcloud builds submit "$LZV_ROOT/tests/fixtures/t25" --tag="$IMGPATH:t25" --project="$PROJ" --region="$LZV_REGION" \
  --gcs-source-staging-dir="gs://$BUCKET/source" --gcs-log-dir="gs://$BUCKET/logs"
V_BUILD="$LZV_LAST_RC"
DIGEST=""
if [[ "$V_REPO" == 0 && "$V_BUILD" == 0 ]]; then
  run_capture gcloud artifacts docker images describe "$IMGPATH:t25" --project="$PROJ" --format='value(image_summary.digest)'
  DIGEST="$(grep -Eo 'sha256:[0-9a-f]{64}' "$LZV_LAST_OUT" | head -1)"
fi
if [[ -z "$DIGEST" ]]; then
  write_result INCONCLUSIVE Enforced "image could not be prepared (repository rc=$V_REPO, build rc=$V_BUILD)" \
    "no image digest available; admission was not tested (build/push permission or staging bucket problem)"
  exit 0
fi
IMG="$IMGPATH@$DIGEST"
cleanup_trap "gcloud artifacts docker images delete $IMG --delete-tags"
note "image digest reference: $IMG"

# --- Attempt 1: unattested digest, Binary Authorization on ---
run_capture gcloud run deploy "$SVC" --image="$IMG" --region="$LZV_REGION" --project="$PROJ" --ingress=internal --no-allow-unauthenticated --binary-authorization=default
expect_denied 'Binary Authorization|is not authorized by policy|unauthorized container image'
V1="$LZV_VERDICT"; R1="$LZV_REASON"; RC1="$LZV_LAST_RC"
if last_output_matches 'Service update rejected by Binary Authorization policy'; then SIG1="Service update rejected by Binary Authorization policy"
elif last_output_matches 'is not authorized by policy'; then SIG1="is not authorized by policy"
else SIG1="other Binary Authorization text"; fi
note "attempt 1 (unattested): exit $RC1; signature: $SIG1"

# --- Create the attestation (gcloud beta) ---
run_capture gcloud beta container binauthz attestations sign-and-create --project="$PROJ" --artifact-url="$IMG" \
  --attestor="$ATTESTOR" --attestor-project="$PROJ" --keyversion="$KEYVER"
RC_ATT="$LZV_LAST_RC"
if [[ "$RC_ATT" != 0 ]]; then
  FINAL=INCONCLUSIVE; [[ "$RC1" == 0 ]] && FINAL=FAIL
  write_result "$FINAL" Enforced "unattested deploy: $V1 (exit $RC1); attestation creation failed (exit $RC_ATT), control not run" \
    "attested control could not be prepared (IAM on note/key, or beta command failure); ${R1:-attempt 1 as expected}"
  exit 0
fi
note "attestation created; waiting 30 s for propagation"
sleep 30

# --- Attempt 2 (control): the same digest, now attested ---
run_capture gcloud run deploy "$SVC" --image="$IMG" --region="$LZV_REGION" --project="$PROJ" --ingress=internal --no-allow-unauthenticated --binary-authorization=default
if [[ "$LZV_LAST_RC" != 0 ]]; then
  note "attempt 2 failed; retrying once after 60 s (propagation is not documented)"
  sleep 60
  run_capture gcloud run deploy "$SVC" --image="$IMG" --region="$LZV_REGION" --project="$PROJ" --ingress=internal --no-allow-unauthenticated --binary-authorization=default
fi
expect_success
V2="$LZV_VERDICT"; R2="$LZV_REASON"

ACTUAL="unattested digest: exit $RC1 ($SIG1); attested same digest: $V2 (exit $LZV_LAST_RC)"
if [[ "$V1" == PASS && "$V2" == PASS ]]; then
  write_result PASS Enforced "$ACTUAL"
elif [[ "$V1" == PASS ]]; then
  write_result INCONCLUSIVE Enforced "$ACTUAL" "unattested image refused but the attested control did not deploy: $R2"
elif [[ "$RC1" == 0 ]]; then
  write_result FAIL Enforced "$ACTUAL" "unattested image was deployed despite REQUIRE_ATTESTATION"
else
  write_result INCONCLUSIVE Enforced "$ACTUAL" "$R1"
fi
