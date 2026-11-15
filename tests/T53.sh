#!/usr/bin/env bash
# T53 (v3 B14): a gateway-bound agent has no route around the gateway. Plan: plans/v3-harness-boundary-tests.md section 3b
# (pre-registered 2026-11-12, before this script). Agent G (egress bound to Agent Gateway), tool direct_probe, no proxy
# settings, 20 s deadline each: unregistered_mcp (the unregistered MCP fixture), example_ip (TCP + TLS to example.com's
# IP with SNI), storage_api (storage.googleapis.com bucket list). Control: call_mcp_tool on the registered fixture (200).
# Reading: "no route" = no connection / deadline / TLS failure, or the gateway's refusal (403 "Egress request is not
# authorized.", signature from T31R run 9). Any other answer, or a TLS session with the real example.com certificate,
# is a response from the real target ("landed").
# Falsified if: any call lands on its target.
# shellcheck disable=SC2016
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib-v3h.sh
source "$(dirname "$0")/lib-v3h.sh"
require_config

RT="$(project_id runtime)"
LZV_SCOPE="projects/$RT"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/agent-gateway-runtime-deploy"
)
header T53 "B14 (Enforced)" "Agent G tries three destinations without the gateway on purpose (no proxy settings); control: the registered MCP tool through the gateway 200" \
  "Each direct attempt either does not connect or is refused by the gateway (unregistered destination); none lands on its target. Falsified if: any call returns a response from the real target. Control: the registered MCP tool through the gateway returns 200 in the same run. Tier: Enforced. 2+ runs." \
  ""
note "plan claim B14; T53 v3 (plan 3b, f4beb25): v2 decision (5c3808a: control enforced, 240.0.0.0/4 = gateway address) with agent G's fixture call using an unbound ID token; no resources are created by this script; no cleanup_trap registered"
AID_G="$(agents_tf '.agent_g.value.id' 2>/dev/null)" || AID_G=""
[[ -n "$AID_G" && "$AID_G" != null ]] || guard_abort "deploy agent G first"
REGION="$LZV_REGION"

# query_tool MESSAGE TOOLNAME -> TR (the tool's function_response object, or empty)
query_tool() {
  export LZV_URL="https://${REGION}-aiplatform.googleapis.com/v1/${AID_G}:streamQuery?alt=sse"
  LZV_BODY="$(jq -cn --arg m "$1" '{class_method:"async_stream_query", input:{user_id:"lzv-t53", message:$m}}')"
  export LZV_BODY
  run_capture_sh 'printf "Authorization: Bearer %s\n" "$(gcloud auth print-access-token)" | curl -sS -N --max-time 240 -H @- -H "Content-Type: application/json" -X POST "$LZV_URL" -d "$LZV_BODY" -w "\nHTTP %{http_code}\n" 2>&1'
  TR="$(sed 's/^data: *//' "$LZV_LAST_OUT" | jq -cR --arg n "$2" 'fromjson? | .. | objects | (.function_response // .functionResponse // empty)
    | select((.name // "") == $n) | (.response // {}) | (if (.result|type) == "object" then .result else . end)
    | select(type == "object")' 2>/dev/null | head -1)"
}
classify() {  # classify TR -> CL (no_route | gateway_refused | landed | unclear)
  local st body err peer ip o1
  st="$(jq -r '(.status // "none") | tostring' <<<"$1")"; body="$(jq -r '.body // ""' <<<"$1")"
  err="$(jq -r '.error // ""' <<<"$1")"; peer="$(jq -r '.peer_cn // ""' <<<"$1")"; ip="$(jq -r '.ip // ""' <<<"$1")"
  o1="${ip%%.*}"
  if [[ -z "$1" ]]; then CL=unclear
  # v2 (plan 3b, 5c3808a): a connection to 240.0.0.0/4 reached the gateway address, not the target (the gateway
  # intercepts TLS, so a certificate name there is the gateway's)
  elif [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$o1" -ge 240 && "$o1" -le 255 ]]; then
    if [[ "$st" == 403 ]]; then CL=gateway_refused; else CL=no_route; fi
  elif [[ "$peer" == *example.com* || "$peer" == *example.org* ]]; then CL=landed
  elif [[ "$st" == 403 && "$body" == *"Egress request is not authorized"* ]]; then CL=gateway_refused
  elif [[ "$st" == none && -n "$err" ]]; then CL=no_route
  elif [[ "$st" != none ]]; then CL=landed
  else CL=unclear; fi
}

query_tool 'Call call_mcp_tool with server "registered" and tool "registered_echo". Reply with the tool result.' call_mcp_tool
CTL="$(jq -r '(.status // "none") | tostring' <<<"${TR:-{\}}")"
CTL_AUTH="$(jq -r '"auth=\(.auth // "-") cnf_present=\(.cnf_present)"' <<<"${TR:-{\}}")"
note "control: registered MCP tool through the gateway status=$CTL ($CTL_AUTH; v3: unbound ID token for the fixture)"
V=PASS; W=""; ROWS=""
for t in unregistered_mcp example_ip storage_api; do
  query_tool "Call direct_probe with target \"$t\". Reply with the tool result." direct_probe
  classify "$TR"
  ROWS+="$t: $CL (ip=$(jq -r '.ip // "-"' <<<"${TR:-{\}}") status=$(jq -r '(.status // "none") | tostring' <<<"${TR:-{\}}") stage=$(jq -r '.stage // "-"' <<<"${TR:-{\}}") err=$(jq -r '(.error // "") | .[0:120]' <<<"${TR:-{\}}")); "
  case "$CL" in
    landed)  V=FAIL; W+="$t landed on its target; " ;;
    unclear) [[ "$V" == FAIL ]] || V=INCONCLUSIVE; W+="$t: no tool result; " ;;
  esac
done
note "direct attempts: $ROWS"
sleep 45
SINCE="$(date -u -v-6M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-6 min' +%Y-%m-%dT%H:%M:%SZ)"
run_capture gcloud logging read "timestamp>=\"$SINCE\" AND logName=\"projects/$RT/logs/networkservices.googleapis.com%2Fgateway_requests\"" --project="$RT" --limit=200 --format=json
note "gateway log (observation, last 6 min): $(v3h_json_last | jq -r '[.[] | (.jsonPayload.authzPolicyInfo.result // .jsonPayload.authzDecision // .jsonPayload.decision // "?")] | group_by(.) | map("\(.[0])=\(length)") | join(", ")' 2>/dev/null)"
if [[ "$CTL" != 200 ]]; then V=INCONCLUSIVE; W="control failed: registered MCP tool status $CTL (v2: control not 200 = INCONCLUSIVE); $W"; fi
write_result "$V" Enforced "control=$CTL ($CTL_AUTH); $ROWS" "${W%; }"
