#!/usr/bin/env bash
# T33 (v2 C): Agent C (Agent Runtime with a PSC interface, perimeter enforced) fetches an allowed and
# a non-allowed host through the explicit proxy (Secure Web Proxy of T16). Read-only for cloud state:
# the agent and the gateway are Terraform-managed (infra/agents deploy_agent_c, infra swp_enabled +
# enable_v2_psci); this script creates nothing and registers no cleanup. Run order: tests/RUN-ORDER-run6.md
# stage 2-7 (agent C deployed after the runtime project is in the enforced perimeter).
# shellcheck disable=SC2016
set -u
source "$(dirname "$0")/lib.sh"
require_config

RT="$(project_id runtime)"
RT_NUM="$(project_number runtime)"
LZV_SCOPE="projects/$RT"
LZV_DOC_REFS=(
  "https://codelabs.developers.google.com/agent-engine-psc-interface-swp"
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/private-service-connect-interface"
  "https://docs.cloud.google.com/secure-web-proxy/docs/monitor-logs"
  "https://docs.cloud.google.com/vertex-ai/docs/general/vpc-service-controls"
)
header T33 V2-C "Agent Runtime with a PSC interface; internet only through Secure Web Proxy over the attachment" \
  'example.com 200 through the proxy; non-allowed host refused on CONNECT (403) with `DENIED` in `gateway_requests`'
note "no resources are created by this script (agent C, gateway and attachment are Terraform-managed); no cleanup_trap registered"
note "agent C fixed targets: allowed=example.com, denied=www.wikipedia.org (tests/fixtures/agent_c/agent.py)"

REGION="$LZV_REGION"
json_last() { sed -n '/^[[{]/,$p' "$LZV_LAST_OUT"; }

# --- Guards (read-only) ---
GW="$(lzv_tf '.swp_gateway_name.value // empty')"
[[ -n "$GW" ]] || guard_abort "swp_gateway_name output is empty: apply with swp_enabled=true"
PSCI="$(lzv_tf '.v2_psci_attachment_name.value // empty')"
[[ -n "$PSCI" ]] || guard_abort "v2_psci_attachment_name output is empty: apply with enable_v2_psci=true"
AID_C="$(agents_tf '.agent_c.value.id' 2>/dev/null)" || AID_C=""
[[ -n "$AID_C" ]] || guard_abort "deploy agent C first (infra/agents deploy_agent_c=true)"
run_capture gcloud network-services gateways describe "$GW" --location="$REGION" --project="$RT"
[[ "$LZV_LAST_RC" == 0 ]] || guard_abort "Secure Web Proxy gateway $GW not found"
run_capture gcloud compute network-attachments describe "$PSCI" --region="$REGION" --project="$RT"
[[ "$LZV_LAST_RC" == 0 ]] || guard_abort "network attachment $PSCI not found"
run_capture gcloud access-context-manager policies list --organization="$(org_id)" --format=json
POLNAME="$(json_last | jq -r --arg g "folders/$(folder_id root)" '[.[] | select((.scopes // []) | index($g))][0].name // empty' | sed 's#^accessPolicies/##')"
[[ -n "$POLNAME" ]] || guard_abort "no access policy scoped to the test folder"
run_capture gcloud access-context-manager perimeters describe lzv_ai --policy="$POLNAME" --format=json
IN_STATUS="$(json_last | jq -r --arg p "projects/$RT_NUM" '[(.status.resources // [])[] | select(. == $p)] | length')"
[[ "$IN_STATUS" == 1 ]] || guard_abort "the runtime project is not in the enforced perimeter (status); T33 needs the enforced perimeter"
note "guards ok: gateway $GW, attachment $PSCI, agent C $AID_C, runtime project in enforced perimeter"

START="$(lzv_ts)"

# probe_agent TARGET VIA(true|false) -> sets P_RC (http), P_STATUS (number or empty), P_ERR, P_HAVE (0/1: a tool result seen)
probe_agent() {
  local target="$1" via="$2" region frs
  region="${AID_C#*/locations/}"; region="${region%%/*}"
  export LZV_URL="https://${region}-aiplatform.googleapis.com/v1/${AID_C}:streamQuery?alt=sse"
  LZV_BODY="$(jq -cn --arg m "Call fetch_probe with target \"$target\" and via_proxy $via. Reply with the tool result." \
    '{class_method:"async_stream_query", input:{user_id:"lzv-t33", message:$m}}')"
  export LZV_BODY
  run_capture_sh 'out="$(printf "Authorization: Bearer %s\n" "$(gcloud auth print-access-token)" | curl -sS -N --max-time 240 -H @- -H "Content-Type: application/json" -X POST "$LZV_URL" -d "$LZV_BODY" -w "\nHTTP %{http_code}\n" 2>&1)"; printf "%s\n" "$out"; case "$out" in *HTTP\ 200) exit 0 ;; esac; exit 1'
  P_RC="$LZV_LAST_RC"
  frs="$(sed 's/^data: *//' "$LZV_LAST_OUT" | jq -cR 'fromjson? | .. | objects | (.function_response // .functionResponse // empty)
    | (.response // {}) | (if (type == "object" and (.result | type) == "object") then .result else . end)' 2>/dev/null | tail -1)"
  P_HAVE=0; P_STATUS=""; P_ERR=""
  if [[ -n "$frs" ]]; then
    P_HAVE=1
    P_STATUS="$(jq -r '(.status // "") | tostring' <<<"$frs" 2>/dev/null)"
    P_ERR="$(jq -r '(.error // "") | tostring' <<<"$frs" 2>/dev/null | cut -c1-300)"
  fi
  note "probe $target via_proxy=$via: http_rc=$P_RC tool_result=$P_HAVE status=${P_STATUS:-none} error=${P_ERR:-none}"
}

# --- Case 1: allowed host through the proxy (positive control) ---
V1=INCONCLUSIVE; R1=""
probe_agent allowed true
if [[ "$P_HAVE" == 1 && "$P_STATUS" == 200 ]]; then V1=PASS; OBS1="allowed host via proxy: 200"
elif [[ "$P_HAVE" == 1 ]]; then OBS1="allowed host via proxy: no 200 (status ${P_STATUS:-none}, ${P_ERR:-no error})"; R1="allowed host not reachable through the proxy from agent C"
else OBS1="allowed host via proxy: no tool result (http_rc=$P_RC)"; R1="agent C returned no fetch_probe result"; fi

# --- Case 2: non-allowed host through the proxy ---
V2=INCONCLUSIVE; R2=""
probe_agent denied true
if [[ "$P_HAVE" == 1 && "$P_STATUS" == 200 ]]; then
  V2=FAIL; OBS2="non-allowed host reached through the proxy (200)"; R2="proxy allowed a host outside the allow rule"
elif [[ "$P_HAVE" == 1 && ( "$P_STATUS" == 403 || "$P_ERR" =~ 403 ) ]]; then
  ERR2="${P_ERR:-status 403}"
  DENY_FILTER="logName=\"projects/$RT/logs/networkservices.googleapis.com%2Fgateway_requests\" AND jsonPayload.enforcedGatewaySecurityPolicy.matchedRules.action=\"DENIED\" AND timestamp>=\"$START\""
  FOUND=0
  for _ in 1 2 3 4 5; do   # gateway logs lag
    run_capture gcloud logging read "$DENY_FILTER" --project="$RT" --limit=5 --format=json
    if last_output_matches 'DENIED'; then FOUND=1; break; fi
    sleep 30
  done
  if [[ "$FOUND" == 1 ]]; then
    WIKI=0; grep -qi 'wikipedia' "$LZV_LAST_OUT" && WIKI=1
    V2=PASS; OBS2="non-allowed host: refused on CONNECT (403: ${ERR2:0:120}); gateway_requests DENIED entry present (names wikipedia: $WIKI)"
  else
    OBS2="non-allowed host: 403 seen (${ERR2:0:120}); no gateway_requests DENIED entry since $START"
    R2="403 seen but no gateway_requests DENIED entry found in 150 s (log lag?)"
  fi
elif [[ "$P_HAVE" == 1 ]]; then
  OBS2="non-allowed host: no 403 (status ${P_STATUS:-none}, ${P_ERR:-no error})"; R2="neither 403 on CONNECT nor 200 (client error text UNVERIFIED): ${P_ERR:-none}"
else
  OBS2="non-allowed host: no tool result (http_rc=$P_RC)"; R2="agent C returned no fetch_probe result"
fi

ACTUAL="$OBS1; $OBS2"
if [[ "$V1" != PASS ]]; then
  write_result INCONCLUSIVE Enforced "$ACTUAL" "positive control (allowed host via proxy) did not succeed, so the denial proves nothing: ${R1:-n/a}"
else
  FINAL="$(verdict_merge "$V1" "$V2")"
  if [[ "$FINAL" == PASS ]]; then write_result PASS Enforced "$ACTUAL"; else write_result "$FINAL" Enforced "$ACTUAL" "denied host: $R2"; fi
fi
