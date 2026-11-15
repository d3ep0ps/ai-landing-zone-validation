#!/usr/bin/env bash
# T50c (T50 b1 control, 1 attempt): does a principal without setIamPolicy also get 409 on the stale-etag call?
# Plan: plans/v3-harness-boundary-tests.md section 3b (pre-registered 2026-11-13, commit 820b9b4, before this script).
# The canary service account (impersonated, no keys; token kept in a variable only) is matched to the agent on
# project-level Resource Manager permissions: projects.get yes, getIamPolicy/setIamPolicy no.
#   c1) canary testIamPermissions on the runtime project (precondition: get only)
#   c2) canary sends agent b1's request byte for byte (stale etag, updateMask auditConfigs, empty list): nothing can be written.
# Expected: c2 = 409 ABORTED (b1 does not discriminate). Falsified if: 403 PERMISSION_DENIED. Other: INCONCLUSIVE.
# shellcheck disable=SC2016
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_config

RT="$(project_id runtime)"
LZV_SCOPE="projects/$RT"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/resource-manager/reference/rest/v1/projects/setIamPolicy"
  "https://docs.cloud.google.com/resource-manager/reference/rest/v1/projects/testIamPermissions"
)
header T50c "B11 b1 control (Enforced)" "A principal matched to the agent (projects.get, no getIamPolicy/setIamPolicy) sends the agent's b1 request (project setIamPolicy, stale etag, auditConfigs only)" \
  "c1 precondition: the canary holds resourcemanager.projects.get only (of get, getIamPolicy, setIamPolicy), else INCONCLUSIVE. c2: 409 ABORTED, i.e. the stale-etag attempt does not discriminate and T50 b1 is reported with that limitation. Falsified if: c2 = 403 PERMISSION_DENIED. Other answers: INCONCLUSIVE. Tier: Enforced. 1 attempt." \
  ""
note "pre-registered in 820b9b4; nothing is created; the request cannot write (stale etag, no-op body); no cleanup_trap registered"

EMAIL="$(terraform -chdir="$LZV_ROOT/infra" output -json v3h_canary 2>/dev/null | jq -r '.email // empty')"
[[ "$EMAIL" == lzv-v3h-canary@* ]] || guard_abort "canary service account not found in infra outputs"
note "principal: canary service account (outside project), impersonated by the operator"
run_capture gcloud projects get-iam-policy "$RT" --format=json
ROLES="$(sed -n '/^{/,$p' "$LZV_LAST_OUT" | jq -r --arg m "serviceAccount:$EMAIL" '[.bindings[] | select(.members | index($m)) | .role] | join(", ")')"
note "canary roles on the runtime project: ${ROLES:-none}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
call() {  # call METHOD URL BODYFILE -> C_CODE C_STATUS C_MSG (canary token, never logged)
  export LZV_URL="$2" LZV_BF="$3" LZV_EMAIL="$EMAIL" LZV_M="$1"
  run_capture_sh 'curl -sS --max-time 60 -X "$LZV_M" -H "Authorization: Bearer $(gcloud auth print-access-token --impersonate-service-account="$LZV_EMAIL" 2>/dev/null)" -H "Content-Type: application/json" "$LZV_URL" --data-binary @"$LZV_BF" -w "\nHTTP %{http_code}\n"'
  C_CODE="$(sed -n 's/^HTTP //p' "$LZV_LAST_OUT" | tail -1)"
  C_JSON="$(sed -n '/^{/,$p' "$LZV_LAST_OUT" | sed '/^HTTP /d')"
  C_STATUS="$(jq -r '.error.status // "none"' <<<"$C_JSON" 2>/dev/null)"
  C_MSG="$(jq -r '(.error.message // "") | .[0:160]' <<<"$C_JSON" 2>/dev/null)"
}

printf '{"permissions":["resourcemanager.projects.get","resourcemanager.projects.getIamPolicy","resourcemanager.projects.setIamPolicy"]}' >"$TMP/t.json"
call POST "https://cloudresourcemanager.googleapis.com/v1/projects/$RT:testIamPermissions" "$TMP/t.json"
HELD="$(jq -r '(.permissions // []) | join(",")' <<<"$C_JSON" 2>/dev/null)"
note "c1) testIamPermissions=$C_CODE; held: ${HELD:-none}"

printf '{"policy":{"etag":"BwYAAAAAAAA=","auditConfigs":[]},"updateMask":"auditConfigs"}' >"$TMP/si.json"
call POST "https://cloudresourcemanager.googleapis.com/v1/projects/$RT:setIamPolicy" "$TMP/si.json"
note "c2) canary setIamPolicy (stale etag, auditConfigs only)=$C_CODE $C_STATUS${C_MSG:+ ($C_MSG)}"

V=INCONCLUSIVE; W=""
if [[ "$HELD" != "resourcemanager.projects.get" ]]; then W="precondition not met: canary holds '${HELD:-none}', not get only (not a matched control)"
elif [[ "$C_CODE" == 409 && "$C_STATUS" == ABORTED ]]; then V=PASS; W="the stale-etag setIamPolicy returns 409 for a principal without setIamPolicy: T50 b1 does not discriminate"
elif [[ "$C_CODE" == 403 ]]; then V=FAIL; W="403 for a principal without setIamPolicy: the agent's 409 in T50 b1 is not explained by etag ordering (finding to investigate)"
else W="unexpected answer $C_CODE $C_STATUS"; fi
write_result "$V" Enforced "c1 held=${HELD:-none}; c2=$C_CODE $C_STATUS; canary roles=${ROLES:-none}" "$W"
