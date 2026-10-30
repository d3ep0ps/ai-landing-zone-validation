#!/usr/bin/env bash
# T17: Cloud Run requires Binary Authorization via run.allowedBinaryAuthorizationPolicies.
# shellcheck disable=SC2016,SC2119
set -u
source "$(dirname "$0")/lib.sh"
require_config

LZV_SCOPE="projects/$(project_id mcp) (inherits folder policy)"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/binary-authorization/docs/run/requiring-binauthz-cloud-run"
  "https://docs.cloud.google.com/binary-authorization/docs/run/enabling-binauthz-cloud-run"
  "https://docs.cloud.google.com/binary-authorization/docs/run/configure-policy-cloud-run"
)
header T17 P3 'run.allowedBinaryAuthorizationPolicies = default (folder)' \
  'Effective = `default`; deploy refused. Record whether the refusal names the org policy or a Binary Authorization admission rule'

json_last() { sed -n '/^[[{]/,$p' "$LZV_LAST_OUT"; }

PROJ="$(project_id mcp)"
IMG="us-docker.pkg.dev/cloudrun/container/hello"
SVC_BAD="$(lzv_name t17x)"
SVC_OK="$(lzv_name t17c)"

# Configured part
effective_policy run.allowedBinaryAuthorizationPolicies --project="$PROJ"
eff="$(json_last | jq -r '[.spec.rules[]?.values.allowedValues[]?] | any(. == "default" or . == "is:default")' 2>/dev/null)"
if [[ "$eff" != true ]]; then
  write_result FAIL Configured "effective allowedValues do not contain default" "pre-registered expectation Effective = default not met"
  exit 0
fi
note "Configured part: effective allowedValues contains default"

cleanup_run_service "$SVC_OK" "$PROJ"
cleanup_run_service "$SVC_BAD" "$PROJ"

# Enforced part: no --binary-authorization flag
run_capture gcloud run deploy "$SVC_BAD" --image="$IMG" --region="$LZV_REGION" --project="$PROJ" --ingress=internal --no-allow-unauthenticated
bad_rc="$LZV_LAST_RC"
expect_denied 'run\.allowedBinaryAuthorizationPolicies|[Bb]inary [Aa]uthorization|not authorized by policy'
v_bad="$LZV_VERDICT"; r_bad="$LZV_REASON"
if last_output_matches 'run\.allowedBinaryAuthorizationPolicies'; then
  naming="refusal names the org policy constraint run.allowedBinaryAuthorizationPolicies"
elif last_output_matches 'not authorized by policy|admission|[Bb]inary [Aa]uthorization'; then
  naming="refusal names a Binary Authorization admission rule (not the org policy constraint)"
else
  naming="refusal text names neither"
fi
note "$naming"

# Control: with --binary-authorization=default
run_capture gcloud run deploy "$SVC_OK" --image="$IMG" --region="$LZV_REGION" --project="$PROJ" --ingress=internal --no-allow-unauthenticated --binary-authorization=default
expect_success
v_ok="$LZV_VERDICT"

if [[ "$v_bad" == PASS && "$v_ok" == PASS ]]; then
  write_result PASS Enforced "effective=default; deploy without --binary-authorization refused; control with default accepted; $naming"
elif [[ "$v_bad" == PASS ]]; then
  write_result INCONCLUSIVE Enforced "deploy without flag refused but control deploy failed; $naming" "control deploy with --binary-authorization=default failed, denial may be unrelated"
elif [[ "$bad_rc" == 0 ]]; then
  write_result FAIL Configured "effective=default but deploy without --binary-authorization succeeded (control: $v_ok)" "$r_bad"
else
  write_result INCONCLUSIVE Configured "effective=default; deploy failed without the verified signature (control: $v_ok)" "$r_bad"
fi
