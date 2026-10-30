#!/usr/bin/env bash
# T34 (v2 C): the same agent C fetches the allowed host WITHOUT the proxy (via_proxy=false). Paired control:
# T33 (in this script the allowed host via the proxy is repeated first, same session). Read-only for cloud state:
# the agent and the gateway are Terraform-managed (infra/agents deploy_agent_c, infra swp_enabled +
# enable_v2_psci); this script creates nothing and registers no cleanup. Run order: tests/RUN-ORDER-run6.md
# stage 2-7, after T33 (agent C deployed after the runtime project is in the enforced perimeter).
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
header T34 V2-C "Agent Runtime with a PSC interface; egress firewall deny-all attributes the bypass failure" \
  'Connection fails (not a DNS error) **and** the firewall log shows a deny for `lzv-swp-deny-egress-all` from 10.77.4.0/28; without that log entry: INCONCLUSIVE'
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
[[ "$IN_STATUS" == 1 ]] || guard_abort "the runtime project is not in the enforced perimeter (status); T34 needs the enforced perimeter"
note "guards ok: gateway $GW, attachment $PSCI, agent C $AID_C, runtime project in enforced perimeter"


# probe_agent TARGET VIA(true|false) -> sets P_RC (http), P_STATUS (number or empty), P_ERR, P_HAVE (0/1: a tool result seen)
probe_agent() {
  local target="$1" via="$2" region frs
  region="${AID_C#*/locations/}"; region="${region%%/*}"
  export LZV_URL="https://${region}-aiplatform.googleapis.com/v1/${AID_C}:streamQuery?alt=sse"
  LZV_BODY="$(jq -cn --arg m "Call fetch_probe with target \"$target\" and via_proxy $via. Reply with the tool result." \
    '{class_method:"async_stream_query", input:{user_id:"lzv-t34", message:$m}}')"
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


# ip2int / in_cidr: IPv4 membership without external tools
ip2int() { local IFS=.; local a b c d; read -r a b c d <<<"$1"; echo $(( (a << 24) | (b << 16) | (c << 8) | d )); }
in_cidr() {  # in_cidr IP CIDR
  local ip base bits mask
  ip="$(ip2int "$1")"; base="$(ip2int "${2%/*}")"; bits="${2#*/}"
  mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  (( (ip & mask) == (base & mask) ))
}

# Attachment CIDR from the live subnet (not hard-coded); the deny rule must exist.
run_capture gcloud compute networks subnets describe lzv-swp-psci --region="$REGION" --project="$RT" --format='value(ipCidrRange)'
[[ "$LZV_LAST_RC" == 0 ]] || guard_abort "attachment subnet lzv-swp-psci not found"
CIDR="$(tr -d '[:space:]' <"$LZV_LAST_OUT")"
[[ "$CIDR" =~ ^[0-9.]+/[0-9]+$ ]] || guard_abort "cannot read the attachment CIDR"
run_capture gcloud compute firewall-rules describe lzv-swp-deny-egress-all --project="$RT" --format='value(name,logConfig.enable,direction,disabled)'
[[ "$LZV_LAST_RC" == 0 ]] || guard_abort "firewall rule lzv-swp-deny-egress-all not found"
grep -q 'True' "$LZV_LAST_OUT" || guard_abort "firewall rule lzv-swp-deny-egress-all has logging off"
note "attachment CIDR $CIDR; deny rule lzv-swp-deny-egress-all present with logging"

# --- Paired control: allowed host via the proxy in the same session ---
V1=INCONCLUSIVE; R1=""
probe_agent allowed true
if [[ "$P_HAVE" == 1 && "$P_STATUS" == 200 ]]; then V1=PASS; OBS1="control: allowed host via proxy 200"
else OBS1="control: allowed host via proxy not 200 (tool_result=$P_HAVE status=${P_STATUS:-none})"; R1="paired control (via proxy) failed: ${P_ERR:-no tool result}"; fi

# --- Attempt: the same host without the proxy ---
BYPASS_START="$(lzv_ts)"
probe_agent allowed false
V2=INCONCLUSIVE; R2=""; FAIL_KIND=""
DNS_RE='Name or service not known|Temporary failure in name resolution|NameResolutionError|Failed to resolve|getaddrinfo|gaierror'
if [[ "$P_HAVE" != 1 ]]; then
  OBS2="bypass: no tool result (http_rc=$P_RC)"; R2="agent C returned no fetch_probe result"
elif [[ "$P_STATUS" == 200 ]]; then
  V2=FAIL; OBS2="bypass: direct connection succeeded (200)"; R2="the direct connection was not blocked"
elif [[ -z "$P_ERR" ]]; then
  OBS2="bypass: no status and no error"; R2="unclassified tool result"
elif [[ "$P_ERR" =~ $DNS_RE ]]; then
  V2=FAIL; OBS2="bypass: DNS error (${P_ERR:0:120})"; R2="expected a connection failure, got a DNS resolution error"
else
  FAIL_KIND="${P_ERR:0:120}"
  FW_FILTER="logName=\"projects/$RT/logs/compute.googleapis.com%2Ffirewall\" AND jsonPayload.disposition=\"DENIED\" AND jsonPayload.rule_details.reference:\"lzv-swp-deny-egress-all\" AND timestamp>=\"$BYPASS_START\""
  HIT=0; SRC=""
  for _ in $(seq 1 10); do   # firewall logs lag: poll up to about 10 minutes
    run_capture gcloud logging read "$FW_FILTER" --project="$RT" --limit=50 --format=json
    for ip in $(json_last | jq -r '[.[]?.jsonPayload.connection.src_ip // empty] | unique[]' 2>/dev/null); do
      if in_cidr "$ip" "$CIDR"; then HIT=1; SRC="$ip"; break; fi
    done
    [[ "$HIT" == 1 ]] && break
    sleep 60
  done
  if [[ "$HIT" == 1 ]]; then
    DST="$(json_last | jq -r --arg s "$SRC" '[.[]? | select(.jsonPayload.connection.src_ip == $s) | .jsonPayload.connection.dest_ip] | unique | join(",")' 2>/dev/null | cut -c1-80)"
    V2=PASS; OBS2="bypass: connection failed (${FAIL_KIND}); firewall log DENIED by lzv-swp-deny-egress-all from $SRC (in $CIDR) to ${DST:-?}"
  else
    OBS2="bypass: connection failed (${FAIL_KIND}); no firewall log DENIED entry for lzv-swp-deny-egress-all from $CIDR in about 10 minutes"
    R2="failure not attributed to the firewall (no log entry; no NAT or route would also fail)"
  fi
fi

ACTUAL="$OBS1; $OBS2"
if [[ "$V2" == FAIL ]]; then
  write_result FAIL Enforced "$ACTUAL" "$R2"
elif [[ "$V1" != PASS ]]; then
  write_result INCONCLUSIVE Enforced "$ACTUAL" "$R1; bypass reason: ${R2:-n/a}"
elif [[ "$V2" == PASS ]]; then
  write_result PASS Enforced "$ACTUAL"
else
  write_result INCONCLUSIVE Enforced "$ACTUAL" "$R2"
fi
