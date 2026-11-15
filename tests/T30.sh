#!/usr/bin/env bash
# T30 (v2 B): tool authorisation at the Agent Gateway. Agent G (bound to the egress gateway) calls a
# registered MCP tool (control) and an unregistered MCP tool. Pre-registered row: EXECUTION-PLAN.md
# Appendix E, E3, T30. Single stage; nothing is created by this script (gateway, registry, Cloud Run
# fixtures and agent G are built by the human per infra/README.md "v2 B"; wait about 4 minutes after
# registry changes). A gateway 403 is told apart from an origin (Cloud Run) 403 by the log verdict
# and by the absence of a request log on the origin service.
# shellcheck disable=SC2016
set -u
source "$(dirname "$0")/lib.sh"
require_config

RT="$(project_id runtime)"
LZV_SCOPE="projects/$RT"
LZV_DOC_REFS=(
  "https://codelabs.developers.google.com/cloudnet-agent-gateway"
  "https://codelabs.developers.google.com/agw-cuj-arun-egress-gmcp"
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/gateways/set-up-agent-gateway"
)
# Header fix (2026-10-30, RUN-ORDER-run9.md R5): runs 6-8 passed the control text as a separate argument, so
# result.json "expected" held the control text and the expected text went to the stage slot. The control
# text is now part of the check text; the expected text is unchanged.
header T30 "B" "Agent behind Agent Gateway calls a registered and an unregistered MCP tool; control: Registered tool" \
  'Unregistered: HTTP 403 and a gateway log entry with verdict `DENIED`; registered: answered'
note "no resources are created by this script; no cleanup_trap registered"
note "unverified: gateway verdict read from gateway_requests jsonPayload.authzPolicyInfo.result (field seen in run-7 logs); the 403 body text is not asserted"

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

# --- Control: registered tool answered ---
T0C="$(lzv_ts)"
query_g 'Call call_mcp_tool with server "registered" and tool "registered_echo". Reply with the tool result.'
if [[ "$G_STATUS" == 200 && "$G_BODY" == *registered_echo:\ OK* ]]; then
  VC=PASS; OC="registered_echo answered (200)"
else
  VC=INCONCLUSIVE; OC="registered_echo not answered (status=$G_STATUS err=${G_ERR:-none})"
fi
AUTH_C="${G_AUTH:-none}"
# Run 8 (R1): did the control reach the container? Informational, not part of the verdict (VPC egress check).
run_capture gcloud logging read "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${LZV_MCP_REG_SERVICE:-lzv-mcp-reg}\" AND timestamp>=\"$T0C\"" \
  --project="$RT" --limit=5 --format=json
REG_ORIGIN_N="$(json_last | jq 'length' 2>/dev/null || echo '?')"
note "origin (Cloud Run) request-log entries for the registered service since the control call: $REG_ORIGIN_N"
OC="$OC; registered origin entries=$REG_ORIGIN_N"

# --- Attempt: unregistered tool ---
T1="$(lzv_ts)"
query_g 'Call call_mcp_tool with server "unregistered" and tool "unregistered_echo". Reply with the tool result.'
AUTH_U="${G_AUTH:-none}"; ST_U="$G_STATUS"
note "token type used by the agent: registered call=$AUTH_C, unregistered call=$AUTH_U"
VU=INCONCLUSIVE; WU=""
if [[ "$ST_U" == 200 ]]; then
  VU=FAIL; OU="unregistered tool answered (200)"; WU="finding: the unregistered MCP tool was reachable through the gateway"
elif [[ "$ST_U" == 403 ]]; then
  log_find "timestamp>=\"$T1\" AND logName=\"projects/$RT/logs/networkservices.googleapis.com%2Fgateway_requests\" AND jsonPayload.authzPolicyInfo.result=\"DENIED\" AND httpRequest.requestUrl:\"${LZV_MCP_UNREG_SERVICE:-lzv-mcp-unreg}\""
  note "gateway_requests entries with authzPolicyInfo.result=DENIED for the unregistered service: $FOUND_N ${FOUND_SUM}"
  DEN_N="$FOUND_N"
  if (( DEN_N == 0 )); then
    run_capture gcloud logging read "timestamp>=\"$T1\" AND \"DENIED\"" --project="$RT" --limit=5 --format=json
    note "broad filter (DENIED only, no gateway name): $(json_last | jq 'length' 2>/dev/null || echo '?') entries; not used for the verdict"
  fi
  run_capture gcloud logging read "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${LZV_MCP_UNREG_SERVICE:-lzv-mcp-unreg}\" AND timestamp>=\"$T1\"" \
    --project="$RT" --limit=5 --format=json
  ORIGIN_N="$(json_last | jq 'length' 2>/dev/null || echo '?')"
  note "origin (Cloud Run) request-log entries for the unregistered service since the call: $ORIGIN_N"
  if (( DEN_N > 0 )) && [[ "$ORIGIN_N" == 0 ]]; then
    VU=PASS; OU="unregistered tool: 403, gateway DENIED log entry, no origin request"
  elif (( DEN_N > 0 )); then
    OU="unregistered tool: 403 and DENIED entry, but the origin also logged a request ($ORIGIN_N)"; WU="gateway 403 not distinguishable from an origin 403"
  else
    OU="unregistered tool: 403 without a gateway DENIED entry"; WU="403 not attributable to the gateway (origin 403 not excluded)"
  fi
else
  OU="unregistered tool: no 403 (status=$ST_U err=${G_ERR:-none})"; WU="no tool result with HTTP 403 (status=$ST_U); error text not asserted"
fi

ACTUAL="control: $OC; $OU; token type registered=$AUTH_C unregistered=$AUTH_U"
if [[ "$VC" != PASS ]]; then
  write_result INCONCLUSIVE Enforced "$ACTUAL" "positive control (registered tool) did not answer, so the denial proves nothing"
elif [[ "$VU" == PASS ]]; then
  write_result PASS Enforced "$ACTUAL"
else
  write_result "$VU" Enforced "$ACTUAL" "${WU:-unregistered call not classified}"
fi
