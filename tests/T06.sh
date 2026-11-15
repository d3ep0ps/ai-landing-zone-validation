#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2119
# T06: discoveryengine.managed.disableCustomMcpServerConnector, effective policy before and after
# Usage: T06.sh before | after
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_config

STAGE="${1:-}"
[[ "$STAGE" == before || "$STAGE" == after ]] || lzv_die "usage: T06.sh before|after"

C="constraints/discoveryengine.managed.disableCustomMcpServerConnector"
F="$(folder_id root)"
P="$(project_id mcp)"
LZV_SCOPE="folders/$F; projects/$P"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/gemini/enterprise/docs/connectors/custom-mcp-server/override-constraint-for-custom-mcp-data-stores"
  "https://docs.cloud.google.com/gemini/enterprise/docs/connectors/managed-policy-constraints-overview"
  "https://docs.cloud.google.com/organization-policy/reference/org-policy-constraints"
)

header T06 I5 \
  '`discoveryengine.managed.disableCustomMcpServerConnector` (folder)' \
  'Effective = enforced' \
  "$STAGE"

# enforce_of FILE -> true|false|unset (first rule's enforce flag)
enforce_of() {
  jq -r '(.spec.rules[0].enforce // "unset") | tostring | ascii_downcase' "$1" 2>/dev/null || echo unreadable
}

# observe: sets OBS_F and OBS_P (enforce value or "error")
observe() {
  effective_policy "$C" "--folder=$F"
  if [[ "$LZV_LAST_RC" == 0 ]]; then OBS_F="$(enforce_of "$LZV_LAST_OUT")"; else OBS_F=error; fi
  effective_policy "$C" "--project=$P"
  if [[ "$LZV_LAST_RC" == 0 ]]; then OBS_P="$(enforce_of "$LZV_LAST_OUT")"; else OBS_P=error; fi
  note "effective enforce: folder root=$OBS_F; project mcp=$OBS_P"
}

if [[ "$STAGE" == before ]]; then
  observe
  write_stage PASS "recorded before folder policy: folder root enforce=$OBS_F; project mcp enforce=$OBS_P"
  exit 0
fi

# after: guard, our folder policy must exist.
run_capture gcloud org-policies describe "$C" "--folder=$F" --format=json --billing-project="$(quota_project)"
if [[ "$LZV_LAST_RC" != 0 ]]; then
  if last_output_matches 'NOT_FOUND|not found'; then
    guard_abort "Stage 2 toggle not applied (no folder policy for $C)"
  fi
  write_result INCONCLUSIVE Configured "folder policy describe failed" "describe of the folder policy failed (exit $LZV_LAST_RC)"
  exit 0
fi

observe
BEFORE_V="$(read_stage before)"
if [[ "$BEFORE_V" == MISSING ]]; then
  BEFORE_NOTE="before stage MISSING (no baseline recorded)"
else
  BEFORE_NOTE="$(jq -r .note "$LZV_DIR/stages/before.json")"
fi
ACTUAL="after: folder root enforce=$OBS_F; project mcp enforce=$OBS_P | $BEFORE_NOTE"

if [[ "$OBS_F" == true && "$OBS_P" == true ]]; then
  if [[ "$BEFORE_V" == MISSING ]]; then
    write_result PASS Configured "$ACTUAL" "before stage missing; baseline not recorded"
  else
    write_result PASS Configured "$ACTUAL"
  fi
elif [[ "$OBS_F" == error || "$OBS_P" == error ]]; then
  write_result INCONCLUSIVE Configured "$ACTUAL" "effective describe failed; see output.txt"
else
  write_result FAIL Configured "$ACTUAL" "effective policy is not enforced"
fi
