#!/usr/bin/env bash
# T31 (v2 B): this is E3 row T31b (EXECUTION-PLAN.md Appendix E, E3). The drafted T31 was dropped
# before it existed; "T31b" does not match the lib.sh ID pattern, so the test ID is T31.
# Two layers on the model path. (1) Agent G (bound to the gateway; exception in the project deny
# policy, T18 form, so IAM allows it) calls the allowed model endpoint (control, answered) and the
# endpoint the gateway registry does not list (expected: gateway 403, DENIED). (2) The same kind of call
# by a non-approved agent (agent B, only if deployed) is refused by the IAM deny policy.
# Single stage; nothing is created here. No deploys: if agent B does not exist, part (2) is recorded as
# not run and the verdict is INCONCLUSIVE for it.
# shellcheck disable=SC2016
set -u
source "$(dirname "$0")/lib.sh"
require_config

RT="$(project_id runtime)"
LZV_SCOPE="projects/$RT"
LZV_DOC_REFS=(
  "https://codelabs.developers.google.com/cloudnet-agent-gateway"
  "https://docs.cloud.google.com/iam/docs/deny-access"
  "https://docs.cloud.google.com/iam/docs/permission-error-messages"
)
# Header fix (2026-10-30, RUN-ORDER-run9.md R5): runs 6-8 passed the control text as a separate argument, so
# result.json "expected" held the control text and the expected text went to the stage slot. The control
# text is now part of the check text; the expected text is unchanged.
header T31 "B" "E3 row T31b: agent behind the gateway, project deny policy (T18 form) with the agent as exception; call a model endpoint the gateway does not allow; control: Allowed endpoint answered" \
  'Gateway refuses (403, `DENIED`) although IAM allows the agent; then the same call by a non-approved agent is refused by the IAM deny policy ("due to an IAM deny policy")'
note "this script implements E3 row T31b under test ID T31"
note "no resources are created by this script; no cleanup_trap registered"
note "unverified: gateway default-deny on model endpoints; verdict read from gateway_requests jsonPayload.authzPolicyInfo.result (field seen in run-7 logs); the 403 body text is not asserted"

REGION="$LZV_REGION"
GWNAME="lzv-gw"
json_last() { sed -n '/^[[{]/,$p' "$LZV_LAST_OUT"; }

# --- Guards (read-only) ---
GWID="$(terraform -chdir="$LZV_ROOT/infra" output -json v2_gateway_id 2>/dev/null | jq -r '. // empty' 2>/dev/null)" || GWID=""
[[ -n "$GWID" ]] || guard_abort "output v2_gateway_id is empty: apply infra/ with enable_v2_gateway=true"
AID_G="$(agents_tf '.agent_g.value.id' 2>/dev/null)" || AID_G=""
[[ -n "$AID_G" ]] || guard_abort "deploy agent G first (infra/agents deploy_agent_g=true)"
PRIN_G="$(agents_tf '.agent_g.value.identity' 2>/dev/null)" || PRIN_G=""
run_capture gcloud alpha network-services agent-gateways describe "$GWNAME" --location="$REGION" --project="$RT"
[[ "$LZV_LAST_RC" == 0 ]] || guard_abort "agent gateway $GWNAME not found in $REGION (exit $LZV_LAST_RC)"
note "guards ok: gateway $GWNAME exists in $REGION; agent G $AID_G; identity ${PRIN_G:-unknown}"

# query_g MESSAGE -> G_RC (curl/http), G_HAVE (0/1 tool result seen), G_STATUS (number|null|none), G_ERR, G_AUTH.
# The agent returns the tool result dict (status, body, auth, error); every field name is from agent_g/agent.py.
query_g() {
  local frs
  export LZV_URL="https://${REGION}-aiplatform.googleapis.com/v1/${AID_G}:streamQuery?alt=sse"
  LZV_BODY="$(jq -cn --arg m "$1" '{class_method:"async_stream_query", input:{user_id:"lzv-gw", message:$m}}')"
  export LZV_BODY
  run_capture_sh 'out="$(printf "Authorization: Bearer %s\n" "$(gcloud auth print-access-token)" | curl -sS -N --max-time 240 -H @- -H "Content-Type: application/json" -X POST "$LZV_URL" -d "$LZV_BODY" -w "\nHTTP %{http_code}\n" 2>&1)"; printf "%s\n" "$out"; case "$out" in *HTTP\ 200) exit 0 ;; esac; exit 1'
  G_RC="$LZV_LAST_RC"
  frs="$(sed 's/^data: *//' "$LZV_LAST_OUT" | jq -cR 'fromjson? | .. | objects | (.function_response // .functionResponse // empty)
    | (.response // {}) | (if (.result|type) == "object" then .result else . end)
    | select(type == "object" and (has("status") or has("error")))
    | {status: .status, error: ((.error // "") | tostring), auth: ((.auth // "") | tostring), body: ((.body // "") | tostring | .[0:300])}' 2>/dev/null)"
  G_HAVE=0; G_STATUS=none; G_ERR=""; G_AUTH=""; G_BODY=""
  if [[ -n "$frs" ]]; then
    G_HAVE=1
    G_STATUS="$(head -1 <<<"$frs" | jq -r '.status | if . == null then "null" else tostring end')"
    G_ERR="$(head -1 <<<"$frs" | jq -r '.error' | cut -c1-200)"
    G_AUTH="$(head -1 <<<"$frs" | jq -r '.auth')"
    G_BODY="$(head -1 <<<"$frs" | jq -r '.body')"
  fi
  note "agent G: http_rc=$G_RC tool_result=$G_HAVE status=$G_STATUS auth=${G_AUTH:-none} err=${G_ERR:-none}"
}

# log_find FILTER: poll Cloud Logging. Run 8 (R1, RUN-ORDER-run8.md): filters name the log and the field seen
# in the run-7 logs (gateway_requests jsonPayload.authzPolicyInfo.result; modelarmor sanitize_operations
# jsonPayload.sanitizationResult.filterMatchState); run 7's free-text filters also counted the query's own
# audit entry and ALLOWED entries (matcher fault). Expected results unchanged. FOUND_N = matching entries,
# FOUND_SUM = logName / resource type of the first match (recorded as observed).
log_find() {
  local filter="$1" i
  FOUND_N=0; FOUND_SUM=""
  for i in 1 2 3 4 5 6; do   # logs lag; 6 x 30 s
    run_capture gcloud logging read "$filter" --project="$RT" --limit=5 --format=json
    FOUND_N="$(json_last | jq 'length' 2>/dev/null || echo 0)"
    [[ "$FOUND_N" =~ ^[0-9]+$ ]] || FOUND_N=0
    (( FOUND_N > 0 )) && break
    (( i < 6 )) && sleep 30
  done
  if (( FOUND_N > 0 )); then
    FOUND_SUM="$(json_last | jq -r '.[0] | "logName=\(.logName // "?") resource=\(.resource.type // "?") ts=\(.timestamp // "?")"' 2>/dev/null | cut -c1-300)"
  fi
  return 0
}

# --- Guard: project deny policy present, G an exception, 10+ minutes old ---
POLICY_ID="lzv-dc1-deny-agent-predict"
run_capture gcloud iam policies list --attachment-point="cloudresourcemanager.googleapis.com/projects/$RT" \
  --kind=denypolicies --format=json --billing-project="$(quota_project)"
[[ "$LZV_LAST_RC" == 0 ]] || guard_abort "cannot list deny policies (exit $LZV_LAST_RC)"
DJ="$(json_last)"; [[ -n "$DJ" ]] || DJ='{}'
SEL='(if type == "array" then . else (.policies // []) end) | [.[] | select((.name | split("/") | last) == $id)]'
DP_N="$(jq --arg id "$POLICY_ID" "$SEL | length" <<<"$DJ")"
[[ "$DP_N" == 1 ]] || guard_abort "deny policy $POLICY_ID not found in the runtime project (apply enable_dc1_deny with G's principal as exception)"
DP_CREATE="$(jq -r --arg id "$POLICY_ID" "$SEL | .[0].createTime // empty
  | if . == \"\" then \"\" else (sub(\"\\\\.[0-9]+Z\$\"; \"Z\") | fromdateiso8601 | tostring) end" <<<"$DJ")"
run_capture gcloud iam policies get "$POLICY_ID" --attachment-point="cloudresourcemanager.googleapis.com/projects/$RT" \
  --kind=denypolicies --format=json --billing-project="$(quota_project)"
[[ "$LZV_LAST_RC" == 0 ]] || guard_abort "cannot read deny policy $POLICY_ID (exit $LZV_LAST_RC)"
DP_EXC="$(json_last | jq -r '[.rules[]?.denyRule.exceptionPrincipals[]?] | join(", ")')"
[[ -n "$PRIN_G" && "$DP_EXC" == *"$PRIN_G"* ]] || guard_abort "agent G principal is not in the deny policy exceptionPrincipals"
[[ -n "$DP_CREATE" ]] || guard_abort "cannot read deny policy createTime"
AGE=$(( $(date -u +%s) - DP_CREATE ))
(( AGE >= 600 )) || guard_abort "deny policy is only ${AGE}s old; wait until 10 minutes have passed since createTime"
note "deny policy $POLICY_ID present, age ${AGE}s, G is an exception"

# --- Control: allowed model endpoint answered ---
query_g 'Call call_model with endpoint "allowed". Reply with the tool result.'
if [[ "$G_STATUS" == 200 ]]; then
  VC=PASS; OC="allowed endpoint answered (200)"
else
  VC=INCONCLUSIVE; OC="allowed endpoint not answered (status=$G_STATUS err=${G_ERR:-none})"
fi

# --- Part 1: endpoint the gateway does not allow ---
T1="$(lzv_ts)"
query_g 'Call call_model with endpoint "blocked". Reply with the tool result.'
note "blocked-endpoint body (first 160 chars, recorded as observed): $(printf '%s' "$G_BODY" | tr '\n' ' ' | cut -c1-160)"
VG=INCONCLUSIVE; WG=""
if [[ "$G_STATUS" == 200 ]]; then
  VG=FAIL; OG="blocked endpoint answered (200)"; WG="finding: the gateway did not refuse the model endpoint that is not in the registry"
elif [[ "$G_STATUS" == 403 ]]; then
  log_find "timestamp>=\"$T1\" AND logName=\"projects/$RT/logs/networkservices.googleapis.com%2Fgateway_requests\" AND jsonPayload.authzPolicyInfo.result=\"DENIED\""
  note "gateway_requests entries with authzPolicyInfo.result=DENIED since the blocked call: $FOUND_N ${FOUND_SUM}"
  if (( FOUND_N > 0 )); then
    VG=PASS; OG="blocked endpoint: 403 and gateway DENIED log entry (IAM allows G: exception in the deny policy)"
  else
    OG="blocked endpoint: 403 without a gateway DENIED entry"; WG="403 not attributable to the gateway (an IAM 403 is not excluded)"
  fi
else
  OG="blocked endpoint: no 403 (status=$G_STATUS err=${G_ERR:-none})"; WG="no tool result with HTTP 403 (status=$G_STATUS); error text not asserted"
fi
if [[ "$VC" != PASS && "$VG" == PASS ]]; then
  VG=INCONCLUSIVE; WG="positive control (allowed endpoint) did not answer, so the refusal proves nothing"
fi

# --- Part 2: non-approved agent B, same kind of call (its own model call), only if B exists ---
AID_B="$(agents_tf '.agent_b.value.id' 2>/dev/null)" || AID_B=""
PRIN_B="$(agents_tf '.agent_b.value.identity' 2>/dev/null)" || PRIN_B=""
VB=INCONCLUSIVE; WB=""
if [[ -z "$AID_B" ]]; then
  OB="non-approved agent part NOT RUN: agent B is not deployed (nothing is deployed by this script)"; WB="agent B not deployed; the IAM deny clause was not run"
elif [[ -n "$PRIN_B" && "$DP_EXC" == *"$PRIN_B"* ]]; then
  guard_abort "agent B principal is an exception of the deny policy; it must not be"
else
  RB="${AID_B#*/locations/}"; RB="${RB%%/*}"
  export LZV_URL="https://${RB}-aiplatform.googleapis.com/v1/${AID_B}:streamQuery?alt=sse"
  export LZV_BODY='{"class_method":"async_stream_query","input":{"user_id":"lzv-t31","message":"Reply with one short sentence: hello."}}'
  run_capture_sh 'out="$(printf "Authorization: Bearer %s\n" "$(gcloud auth print-access-token)" | curl -sS -N --max-time 180 -H @- -H "Content-Type: application/json" -X POST "$LZV_URL" -d "$LZV_BODY" -w "\nHTTP %{http_code}\n" 2>&1)"; printf "%s\n" "$out"; case "$out" in *HTTP\ 200) exit 0 ;; esac; exit 1'
  QB_RC="$LZV_LAST_RC"; QB_DEN=0; QB_PHRASE=0; QB_TEXT=0
  grep -q 'PERMISSION_DENIED' "$LZV_LAST_OUT" && QB_DEN=1
  grep -qi 'IAM deny policy' "$LZV_LAST_OUT" && QB_PHRASE=1
  if sed 's/^data: *//' "$LZV_LAST_OUT" | jq -R 'fromjson? | .. | objects | select(has("text")) | .text | select(type == "string" and length > 0)' 2>/dev/null | grep -q .; then QB_TEXT=1; fi
  note "agent B: http_rc=$QB_RC permission_denied=$QB_DEN phrase 'IAM deny policy'=$QB_PHRASE model_text=$QB_TEXT"
  if [[ "$QB_DEN" == 1 ]]; then
    VB=PASS; OB="non-approved agent B refused with PERMISSION_DENIED (phrase 'IAM deny policy' present=$QB_PHRASE)"
  elif [[ "$QB_RC" == 0 && "$QB_TEXT" == 1 ]]; then
    VB=FAIL; OB="non-approved agent B answered"; WB="finding: the deny policy did not stop agent B"
  else
    OB="agent B query failed without PERMISSION_DENIED (http_rc=$QB_RC)"; WB="agent B query failed without the PERMISSION_DENIED signature"
  fi
fi

ACTUAL="control: $OC; gateway: $OG; $OB"
FINAL="$(verdict_merge "$VG" "$VB")"
REASONS=""
[[ "$VG" == PASS ]] || REASONS+="gateway part: $WG; "
[[ "$VB" == PASS ]] || REASONS+="IAM deny part: $WB; "
if [[ "$FINAL" == PASS ]]; then write_result PASS Enforced "$ACTUAL"; else write_result "$FINAL" Enforced "$ACTUAL" "$REASONS"; fi
