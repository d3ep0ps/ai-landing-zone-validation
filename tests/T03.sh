#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2119
# T03: Cloud Run ingress restricted (run.allowedIngress = internal)
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_config

P="$(project_id mcp)"
LZV_SCOPE="projects/$P"
IMAGE="us-docker.pkg.dev/cloudrun/container/hello"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/run/docs/securing/ingress"
  "https://docs.cloud.google.com/organization-policy/reference/org-policy-constraints"
)

header T03 Baseline \
  '`run.allowedIngress` = internal (folder)' \
  '`--ingress=all` denied, error names `run.allowedIngress`; control succeeds'

CTRL_SVC="$(lzv_name t03)"
DENY_SVC="$(lzv_name t03)"

cleanup_run_service "$DENY_SVC" "$P"
cleanup_run_service "$CTRL_SVC" "$P"

# Positive control: --ingress=internal (and compliant with the other folder policies).
run_capture gcloud run deploy "$CTRL_SVC" --image="$IMAGE" --region="$LZV_REGION" --project="$P" \
  --ingress=internal --binary-authorization=default
expect_success
V_CTRL="$LZV_VERDICT"; R_CTRL="$LZV_REASON"

# Attempt: --ingress=all.
run_capture gcloud run deploy "$DENY_SVC" --image="$IMAGE" --region="$LZV_REGION" --project="$P" \
  --ingress=all --binary-authorization=default
expect_denied 'run\.allowedIngress'
V_DENY="$LZV_VERDICT"; R_DENY="$LZV_REASON"

if [[ "$V_CTRL" != PASS ]]; then
  FINAL=INCONCLUSIVE
  REASON="positive control failed: $R_CTRL"
else
  FINAL="$(verdict_merge "$V_CTRL" "$V_DENY")"
  REASON="${R_DENY:-ok}"
fi

ACTUAL="control(--ingress=internal)=$V_CTRL; attempt(--ingress=all)=$V_DENY"
if [[ "$FINAL" == PASS ]]; then
  write_result PASS Enforced "$ACTUAL"
else
  write_result "$FINAL" Enforced "$ACTUAL" "$REASON"
fi
