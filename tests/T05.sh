#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2119
# T05: vertexai.configurableComputerUseToolSafetyPolicies deny all (effective policy check only)
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_config

C="constraints/vertexai.configurableComputerUseToolSafetyPolicies"
F="$(folder_id root)"
P="$(project_id runtime)"
LZV_SCOPE="folders/$F"
LZV_DOC_REFS=(
  "https://github.com/GoogleCloudPlatform/cloud-foundation-fabric/issues/4276"
  "https://docs.cloud.google.com/vertex-ai/generative-ai/docs/computer-use"
  "https://docs.cloud.google.com/organization-policy/reference/org-policy-constraints"
)

header T05 'New (R)' \
  '`vertexai.configurableComputerUseToolSafetyPolicies` deny all (folder); not in the official constraint reference' \
  'Policy effective = deny all. If the API does not know the constraint: NOT_TESTED + finding'

deny_all() {  # deny_all FILE -> true if any rule has denyAll
  jq -e '[.spec.rules[]? | select(.denyAll == true or .denyAll == "true" or .denyAll == "TRUE")] | length > 0' "$1" >/dev/null 2>&1
}

# Precondition: the API knows the constraint (effective describe on the folder root).
effective_policy "$C" "--folder=$F"
RC_F="$LZV_LAST_RC"
cp "$LZV_LAST_OUT" "$LZV_DIR/.eff-folder"
if [[ "$RC_F" != 0 ]]; then
  if last_output_matches 'NOT_FOUND|not found|[Uu]nknown|INVALID_ARGUMENT|does not exist|[Ii]nvalid'; then
    rm -f "$LZV_DIR/.eff-folder"
    not_tested Documented "constraint unknown to the API (finding): effective describe of $C failed; see output.txt"
  fi
  rm -f "$LZV_DIR/.eff-folder"
  write_result INCONCLUSIVE Configured "effective describe on the folder failed with an unrecognised error" \
    "describe failed (exit $RC_F) without an 'unknown constraint' signature"
  exit 0
fi

# Guard: our folder policy must exist (Stage 2 toggle applied).
run_capture gcloud org-policies describe "$C" "--folder=$F" --format=json --billing-project="$(quota_project)"
if [[ "$LZV_LAST_RC" != 0 ]]; then
  if last_output_matches 'NOT_FOUND|not found'; then
    rm -f "$LZV_DIR/.eff-folder"
    guard_abort "Stage 2 toggle not applied (no folder policy for $C)"
  fi
  rm -f "$LZV_DIR/.eff-folder"
  write_result INCONCLUSIVE Configured "folder policy describe failed" "describe of the folder policy failed (exit $LZV_LAST_RC)"
  exit 0
fi

effective_policy "$C" "--project=$P"
RC_P="$LZV_LAST_RC"
if [[ "$RC_P" == 0 ]] && deny_all "$LZV_DIR/.eff-folder" && deny_all "$LZV_LAST_OUT"; then
  rm -f "$LZV_DIR/.eff-folder"
  write_result PASS Configured "effective policy is deny all at the folder root and in the runtime project"
else
  FD="no"; deny_all "$LZV_DIR/.eff-folder" && FD="yes"
  PD="no"; [[ "$RC_P" == 0 ]] && deny_all "$LZV_LAST_OUT" && PD="yes"
  rm -f "$LZV_DIR/.eff-folder"
  write_result FAIL Configured "denyAll at folder=$FD, at runtime project=$PD" "effective policy does not show a deny-all rule"
fi
