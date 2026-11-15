#!/usr/bin/env bash
# T31R: re-test of T31's first claim (gateway refuses a model call to an unregistered endpoint while IAM
# allows the agent). Design in tests/RUN-ORDER-run9.md "T31R design", human approved 2026-10-30.
# T31 and its run-6 to run-8 results are unchanged.
# Method (differential): between the two stages only the gateway registry changes (Terraform toggle
# v2_gateway_t31r_register_blocked registers https://europe-west1-aiplatform.googleapis.com). IAM does not
# change: same deny policy (same createTime, etag, exceptions), G still an exception.
# Stages: pre | post. The result is written by `post`. Nothing is created by this script.
# shellcheck disable=SC2016
set -u
source "$(dirname "$0")/lib.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in pre|post) ;; *) lzv_die "usage: T31R.sh pre|post" ;; esac

RT="$(project_id runtime)"
LZV_SCOPE="projects/$RT"
LZV_DOC_REFS=(
  "https://codelabs.developers.google.com/cloudnet-agent-gateway"
  "https://docs.cloud.google.com/iam/docs/deny-access"
  "https://docs.cloud.google.com/iam/docs/permission-error-messages"
)
header T31R "B" "Re-test of T31 part 1 (registry differential). Control: Allowed endpoint answered in \`pre\`; IAM state identical in \`pre\` and \`post\`" \
  '`pre`: G'"'"'s call to the unregistered model endpoint is refused (403) although IAM allows G; `post`: after only the registry changes, the same call is answered (200); B is refused by the IAM deny policy ("due to an IAM deny policy")' \
  "$STAGE"
note "no resources are created by this script (agents, gateway, registry, deny policy are Terraform-managed); no cleanup_trap registered"
note "not asserted: the 403 body text and the log entries (recorded as observed, supporting evidence only)"
note "limitation: post shows the registry decides this call, not which gateway component (registry check or IAP policy destination.is_registered) refused it"

REGION="$LZV_REGION"
GWNAME="lzv-gw"
BLOCKED_URL="https://${REGION}-aiplatform.googleapis.com"
POLICY_ID="lzv-dc1-deny-agent-predict"
STATE_FILE="$LZV_DIR/stages/pre-state.json"
json_last() { sed -n '/^[[{]/,$p' "$LZV_LAST_OUT"; }

# --- Guards (read-only), both stages ---
GWID="$(terraform -chdir="$LZV_ROOT/infra" output -json v2_gateway_id 2>/dev/null | jq -r '. // empty' 2>/dev/null)" || GWID=""
[[ -n "$GWID" ]] || guard_abort "output v2_gateway_id is empty: apply infra/ with enable_v2_gateway=true"
AID_G="$(agents_tf '.agent_g.value.id' 2>/dev/null)" || AID_G=""
[[ -n "$AID_G" ]] || guard_abort "deploy agent G first (infra/agents deploy_agent_g=true)"
PRIN_G="$(agents_tf '.agent_g.value.identity' 2>/dev/null)" || PRIN_G=""
AID_B="$(agents_tf '.agent_b.value.id' 2>/dev/null)" || AID_B=""
PRIN_B="$(agents_tf '.agent_b.value.identity' 2>/dev/null)" || PRIN_B=""
run_capture gcloud alpha network-services agent-gateways describe "$GWNAME" --location="$REGION" --project="$RT"
[[ "$LZV_LAST_RC" == 0 ]] || guard_abort "agent gateway $GWNAME not found in $REGION (exit $LZV_LAST_RC)"
note "guards ok: gateway $GWNAME exists in $REGION; agent G $AID_G; agent B ${AID_B:-not deployed}"

# Deny policy: present, G an exception, B not, 10+ minutes old. Sets DP_CREATE, DP_ETAG, DP_EXC.
run_capture gcloud iam policies get "$POLICY_ID" --attachment-point="cloudresourcemanager.googleapis.com/projects/$RT" \
  --kind=denypolicies --format=json --billing-project="$(quota_project)"
[[ "$LZV_LAST_RC" == 0 ]] || guard_abort "cannot read deny policy $POLICY_ID (exit $LZV_LAST_RC)"
DP_CREATE="$(json_last | jq -r '.createTime // empty')"
DP_ETAG="$(json_last | jq -r '.etag // empty')"
DP_EXC="$(json_last | jq -r '[.rules[]?.denyRule.exceptionPrincipals[]?] | sort | join(", ")')"
[[ -n "$DP_CREATE" ]] || guard_abort "cannot read deny policy createTime"
[[ -n "$PRIN_G" && "$DP_EXC" == *"$PRIN_G"* ]] || guard_abort "agent G principal is not in the deny policy exceptionPrincipals"
if [[ -n "$PRIN_B" && "$DP_EXC" == *"$PRIN_B"* ]]; then guard_abort "agent B principal is an exception of the deny policy; it must not be"; fi
DP_EPOCH="$(jq -rn --arg t "$DP_CREATE" '$t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601')"
AGE=$(( $(date -u +%s) - DP_EPOCH ))
(( AGE >= 600 )) || guard_abort "deny policy is only ${AGE}s old; wait until 10 minutes have passed since createTime"
DP_EXC_SHA="$(printf '%s' "$DP_EXC" | shasum -a 256 | cut -c1-16)"
note "deny policy $POLICY_ID: createTime $DP_CREATE, age ${AGE}s, etag $DP_ETAG, exceptions sha256 $DP_EXC_SHA (G an exception, B not)"

# Registry: is the blocked host registered? Sets REG_N (entries naming BLOCKED_URL), REG_CREATE (epoch or empty).
registry_state() {
  run_capture gcloud alpha agent-registry services list --location="$REGION" --project="$RT" --format=json
  [[ "$LZV_LAST_RC" == 0 ]] || guard_abort "cannot list Agent Registry services (exit $LZV_LAST_RC)"
  local sel='[.[]? | select([.. | strings | select(. == $u or . == ($u + "/"))] | length > 0)]'
  REG_N="$(json_last | jq --arg u "$BLOCKED_URL" "$sel | length" 2>/dev/null)"
  [[ "$REG_N" =~ ^[0-9]+$ ]] || guard_abort "cannot read the Agent Registry list"
  REG_CREATE="$(json_last | jq -r --arg u "$BLOCKED_URL" "$sel | .[0].createTime // empty
    | if . == \"\" then \"\" else (sub(\"\\\\.[0-9]+Z\$\"; \"Z\") | fromdateiso8601 | tostring) end" 2>/dev/null)"
  note "registry entries for $BLOCKED_URL: $REG_N${REG_CREATE:+ (createTime epoch $REG_CREATE)}"
}

# query_g MESSAGE -> G_RC, G_HAVE, G_STATUS, G_ERR, G_AUTH, G_BODY (same as T31; fields from agent_g/agent.py).
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

# log_count FILTER -> LOG_N (one read, no polling; supporting evidence only)
log_count() {
  run_capture gcloud logging read "$1" --project="$RT" --limit=5 --format=json
  LOG_N="$(json_last | jq 'length' 2>/dev/null || echo 0)"
  [[ "$LOG_N" =~ ^[0-9]+$ ]] || LOG_N=0
}

BLOCKED_MSG='Call call_model with endpoint "blocked". Reply with the tool result.'

case "$STAGE" in
pre)
  registry_state
  [[ "$REG_N" == 0 ]] || guard_abort "stage pre needs $BLOCKED_URL NOT in the registry (toggle v2_gateway_t31r_register_blocked=false)"

  # (a) control
  query_g 'Call call_model with endpoint "allowed". Reply with the tool result.'
  A_STATUS="$G_STATUS"

  # (b) unregistered endpoint
  T1="$(lzv_ts)"
  query_g "$BLOCKED_MSG"
  B_STATUS="$G_STATUS"
  note "(b) body (first 160 chars, recorded as observed): $(printf '%s' "$G_BODY" | tr '\n' ' ' | cut -c1-160)"
  sleep 60   # logs lag; supporting evidence only
  log_count "timestamp>=\"$T1\" AND logName=\"projects/$RT/logs/networkservices.googleapis.com%2Fgateway_requests\" AND jsonPayload.authzPolicyInfo.result=\"DENIED\""
  note "supporting: gateway_requests DENIED entries since (b): $LOG_N"
  log_count "timestamp>=\"$T1\" AND protoPayload.serviceName=\"iap.googleapis.com\""
  note "supporting: IAP audit entries since (b): $LOG_N"

  # (c) non-approved agent B, its own model call
  C_DEN=0; C_PHRASE=0; C_TEXT=0; C_RC=none
  if [[ -n "$AID_B" ]]; then
    RB="${AID_B#*/locations/}"; RB="${RB%%/*}"
    export LZV_URL="https://${RB}-aiplatform.googleapis.com/v1/${AID_B}:streamQuery?alt=sse"
    export LZV_BODY='{"class_method":"async_stream_query","input":{"user_id":"lzv-t31r","message":"Reply with one short sentence: hello."}}'
    run_capture_sh 'out="$(printf "Authorization: Bearer %s\n" "$(gcloud auth print-access-token)" | curl -sS -N --max-time 180 -H @- -H "Content-Type: application/json" -X POST "$LZV_URL" -d "$LZV_BODY" -w "\nHTTP %{http_code}\n" 2>&1)"; printf "%s\n" "$out"; case "$out" in *HTTP\ 200) exit 0 ;; esac; exit 1'
    C_RC="$LZV_LAST_RC"
    grep -q 'PERMISSION_DENIED' "$LZV_LAST_OUT" && C_DEN=1
    grep -qi 'IAM deny policy' "$LZV_LAST_OUT" && C_PHRASE=1
    if sed 's/^data: *//' "$LZV_LAST_OUT" | jq -R 'fromjson? | .. | objects | select(has("text")) | .text | select(type == "string" and length > 0)' 2>/dev/null | grep -q .; then C_TEXT=1; fi
    note "(c) agent B: http_rc=$C_RC permission_denied=$C_DEN phrase 'IAM deny policy'=$C_PHRASE model_text=$C_TEXT"
  fi

  # pre verdict (design: verdict rules)
  V=INCONCLUSIVE; WHY=""
  OBS="(a) allowed: $A_STATUS; (b) unregistered: $B_STATUS; (c) B: $( [[ -z "$AID_B" ]] && echo "not deployed" || echo "permission_denied=$C_DEN phrase=$C_PHRASE answered=$C_TEXT")"
  if [[ "$B_STATUS" == 200 ]]; then
    V=FAIL; WHY="finding: the gateway did not refuse the model endpoint that is not in the registry"
  elif [[ -n "$AID_B" && "$C_DEN" == 0 && "$C_RC" == 0 && "$C_TEXT" == 1 ]]; then
    V=FAIL; WHY="finding: the deny policy did not stop agent B"
  elif [[ "$A_STATUS" != 200 ]]; then
    WHY="control (a) did not answer 200"
  elif [[ "$B_STATUS" != 403 ]]; then
    WHY="(b) gave no tool result with HTTP 403 (status=$B_STATUS)"
  elif [[ -z "$AID_B" ]]; then
    WHY="agent B not deployed; the IAM deny clause was not run"
  elif [[ "$C_DEN" == 1 && "$C_PHRASE" == 1 ]]; then
    V=PASS
  else
    WHY="(c) agent B not refused with PERMISSION_DENIED and 'IAM deny policy' (permission_denied=$C_DEN phrase=$C_PHRASE)"
  fi
  jq -n --arg c "$DP_CREATE" --arg e "$DP_ETAG" --arg x "$DP_EXC_SHA" --arg b "$B_STATUS" \
    '{deny_create:$c, deny_etag:$e, deny_exceptions_sha:$x, b_status:$b}' >"$STATE_FILE"
  write_stage "$V" "pre: $OBS${WHY:+; $WHY}"
  ;;
post)
  [[ -f "$STATE_FILE" ]] || guard_abort "stage pre not recorded for $RUN_ID (no $STATE_FILE)"
  registry_state
  [[ "$REG_N" -ge 1 ]] || guard_abort "stage post needs $BLOCKED_URL in the registry (apply toggle v2_gateway_t31r_register_blocked=true)"
  SAME=1
  [[ "$(jq -r .deny_create "$STATE_FILE")" == "$DP_CREATE" ]] || SAME=0
  [[ "$(jq -r .deny_etag "$STATE_FILE")" == "$DP_ETAG" ]] || SAME=0
  [[ "$(jq -r .deny_exceptions_sha "$STATE_FILE")" == "$DP_EXC_SHA" ]] || SAME=0
  note "IAM state identical to pre (deny policy createTime, etag, exceptions): $SAME"
  PRE_B="$(jq -r .b_status "$STATE_FILE")"

  # (d) the same call as (b). Up to 5 attempts, 2 minutes apart, until the registry entry is 10 minutes old.
  REG_T0="${REG_CREATE:-$(date -u +%s)}"
  [[ -n "$REG_CREATE" ]] || note "registry entry createTime not read; the 10-minute window counts from now"
  T2="$(lzv_ts)"
  for i in 1 2 3 4 5 6; do
    query_g "$BLOCKED_MSG"
    note "(d) attempt $i: status=$G_STATUS; body (first 160 chars): $(printf '%s' "$G_BODY" | tr '\n' ' ' | cut -c1-160)"
    [[ "$G_STATUS" == 200 ]] && break
    REG_AGE=$(( $(date -u +%s) - REG_T0 ))
    (( REG_AGE >= 600 && i >= 2 )) && break
    (( i < 6 )) && sleep 120
  done
  D_STATUS="$G_STATUS"; REG_AGE=$(( $(date -u +%s) - REG_T0 ))
  log_count "timestamp>=\"$T2\" AND logName=\"projects/$RT/logs/networkservices.googleapis.com%2Fgateway_requests\" AND httpRequest.requestUrl:\"${REGION}-aiplatform.googleapis.com\""
  note "supporting: gateway_requests entries for the regional host since (d): $LOG_N"

  V=INCONCLUSIVE; WHY=""; OBS="(d) after registering: $D_STATUS (registry entry age ${REG_AGE}s); IAM identical: $SAME"
  if [[ "$SAME" != 1 ]]; then
    WHY="IAM state changed between pre and post; the differential does not hold"
  elif [[ "$PRE_B" != 403 ]]; then
    WHY="pre (b) was not 403 (status=$PRE_B); no refusal to attribute"
  elif [[ "$D_STATUS" == 200 ]]; then
    V=PASS
  elif [[ "$D_STATUS" == 403 && "$REG_AGE" -ge 600 ]]; then
    V=FAIL; WHY="finding: still 403 10 minutes after the endpoint was registered; the refusal was not the registry"
  else
    WHY="(d) no 200 and no conclusive 403 (status=$D_STATUS, registry entry age ${REG_AGE}s)"
  fi
  write_stage "$V" "post: $OBS${WHY:+; $WHY}"

  sp="$(read_stage pre)"; reasons=""
  [[ "$sp" == MISSING ]] && { sp=INCONCLUSIVE; reasons+="stage pre missing; "; }
  [[ "$sp" == PASS ]] || reasons+="stage pre: $sp ($(jq -r '.note // empty' "$LZV_DIR/stages/pre.json" 2>/dev/null)); "
  [[ "$V" == PASS ]] || reasons+="stage post: $WHY; "
  final="$(verdict_merge "$sp" "$V")"
  pnote="$(jq -r '.note // "not run"' "$LZV_DIR/stages/pre.json" 2>/dev/null || echo "not run")"
  if [[ "$final" == PASS ]]; then write_result PASS Enforced "${pnote}; post: $OBS"; else write_result "$final" Enforced "${pnote}; post: $OBS" "$reasons"; fi
  ;;
esac
