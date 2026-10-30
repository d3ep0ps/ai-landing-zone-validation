#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2119
# T02: Cloud Run invoker IAM check cannot be disabled (run.managed.requireInvokerIam)
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_config

P="$(project_id mcp)"
LZV_SCOPE="projects/$P"
IMAGE="us-docker.pkg.dev/cloudrun/container/hello"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/run/docs/securing/managing-access"
  "https://docs.cloud.google.com/organization-policy/reference/org-policy-constraints"
  "https://blog.g-gen.co.jp/entry/cloudrun-disable-invoker-iam-check"
)

header T02 Baseline \
  '`run.managed.requireInvokerIam` (folder)' \
  'Both denied; error names `run.managed.requireInvokerIam`'

CTRL_SVC="$(lzv_name t02)"
DENY_SVC="$(lzv_name t02)"

# Register cleanup before deploying; each delete is followed by a describe (expected: not found).
cleanup_run_service "$DENY_SVC" "$P"
cleanup_run_service "$CTRL_SVC" "$P"

# Positive control: a compliant service must deploy.
run_capture gcloud run deploy "$CTRL_SVC" --image="$IMAGE" --region="$LZV_REGION" --project="$P" \
  --ingress=internal --binary-authorization=default
expect_success
V_CTRL="$LZV_VERDICT"; R_CTRL="$LZV_REASON"

# Attempt 1 (create).
run_capture gcloud run deploy "$DENY_SVC" --image="$IMAGE" --region="$LZV_REGION" --project="$P" \
  --ingress=internal --binary-authorization=default --no-invoker-iam-check
expect_denied 'run\.managed\.requireInvokerIam'
V_CREATE="$LZV_VERDICT"; R_CREATE="$LZV_REASON"

# Attempt 2 (update) only makes sense if the compliant service exists.
if [[ "$V_CTRL" == PASS ]]; then
  run_capture gcloud run services update "$CTRL_SVC" --region="$LZV_REGION" --project="$P" --no-invoker-iam-check
  expect_denied 'run\.managed\.requireInvokerIam'
  V_UPDATE="$LZV_VERDICT"; R_UPDATE="$LZV_REASON"
else
  V_UPDATE=INCONCLUSIVE; R_UPDATE="update not attempted: compliant control service did not deploy"
fi

if [[ "$V_CTRL" != PASS ]]; then
  FINAL=INCONCLUSIVE
  REASON="positive control failed: $R_CTRL"
else
  FINAL="$(verdict_merge "$V_CREATE" "$V_UPDATE")"
  REASON="create: ${R_CREATE:-ok}; update: ${R_UPDATE:-ok}"
fi

ACTUAL="control=$V_CTRL; create(--no-invoker-iam-check)=$V_CREATE; update(--no-invoker-iam-check)=$V_UPDATE"
if [[ "$FINAL" == PASS ]]; then
  write_result PASS Enforced "$ACTUAL"
else
  write_result "$FINAL" Enforced "$ACTUAL" "$REASON"
fi
