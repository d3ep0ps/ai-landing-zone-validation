#!/usr/bin/env bash
# T47r (v3 B8 regression, 1 attempt): does the run-6 401 reproduce? Plan: plans/v3-harness-boundary-tests.md section 3b
# (pre-registered 2026-11-12, before this script; human-approved 2026-11-12). Setup as recorded for run 6:
# infra/profiles/v3h-t47r.tfvars (IAP policy V1, no gateway VPC egress), agent G from the UNPINNED requirements file
# (infra/agents agent_g_unpinned=true, build VARIANT=unpinned), default binding (no opt-out). One T47 s2 call: agent G
# call_model "allowed" through the gateway. Resolved versions: agent G prints them at import (Cloud Logging).
# Expected: 401 as in run 6 (F16). If 200: "the run-6 401 did not reproduce on DATE; cause unknown" (stated exactly so).
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
  "https://docs.cloud.google.com/access-context-manager/docs/caa-agent-security"
)
header T47r "B8 regression (Enforced, 1 attempt)" "Run-6 setup rebuilt (IAP policy V1, no gateway VPC egress, agent G unpinned, default binding); one call through the gateway as T47 s2" \
  "401 as in run 6 (F16). If 200: the finding is 'the run-6 401 did not reproduce on DATE; cause unknown'. Versions of google-auth, google-cloud-aiplatform, google-adk and the IAP policy version are recorded. Tier: Enforced (1 attempt). Paid: gateway hours; same-day teardown." \
  ""
note "plan B8 regression; no resources are created by this script; no cleanup_trap registered"
UNP="$LZV_ROOT/infra/agents/build/source-g-unpinned.tar.gz"
[[ -f "$UNP" ]] || guard_abort "build the unpinned agent G tarball first (VARIANT=unpinned agent_g/build.sh)"
note "unpinned tarball sha256 $(shasum -a 256 "$UNP" | cut -c1-16)...; requirements: $(tar -xzOf "$UNP" requirements.txt | tr '\n' ' ')"

REGION="$LZV_REGION"
AID_G="$(agents_tf '.agent_g.value.id' 2>/dev/null)" || AID_G=""
[[ -n "$AID_G" && "$AID_G" != null ]] || guard_abort "deploy agent G first (agent_g_unpinned=true)"
run_capture gcloud alpha network-services agent-gateways describe lzv-gw --location="$REGION" --project="$RT" --format=json
[[ "$LZV_LAST_RC" == 0 ]] || guard_abort "agent gateway lzv-gw not found in $REGION"
IAPV="$(v3h_json_last | jq -r '[.. | objects | .iapPolicyVersion? // empty] | first // "not shown"' 2>/dev/null)"
HAS_NET="$(v3h_json_last | jq -r '[.. | objects | select(has("networkConfig") or has("egressNetworkConfig"))] | length > 0' 2>/dev/null)"
note "gateway: iapPolicyVersion=$IAPV; network egress config present=$HAS_NET"
[[ "$IAPV" != V2 ]] || guard_abort "the gateway uses IAP policy V2; T47r needs V1 (infra/profiles/v3h-t47r.tfvars)"
v3h_engine_env "$AID_G"
CREATED="$(v3h_json_last | jq -r '.createTime // empty' 2>/dev/null)"
[[ "$(jq -r '((.GOOGLE_API_ENABLE_RUNTIME_BOUND_TOKEN // "") | ascii_downcase) == "false"' <<<"$V3H_ENV_JSON")" == false ]] \
  || guard_abort "agent G has the token-binding opt-out; T47r needs the default binding"
v3h_g_versions "${CREATED:-$(date -u -v-3H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-3 hour' +%Y-%m-%dT%H:%M:%SZ)}"

export LZV_URL="https://${REGION}-aiplatform.googleapis.com/v1/${AID_G}:streamQuery?alt=sse"
LZV_BODY="$(jq -cn '{class_method:"async_stream_query", input:{user_id:"lzv-t47r", message:"Call call_model with endpoint \"allowed\". Reply with the tool result."}}')"
export LZV_BODY
run_capture_sh 'printf "Authorization: Bearer %s\n" "$(gcloud auth print-access-token)" | curl -sS -N --max-time 240 -H @- -H "Content-Type: application/json" -X POST "$LZV_URL" -d "$LZV_BODY" -w "\nHTTP %{http_code}\n" 2>&1'
FR="$(sed 's/^data: *//' "$LZV_LAST_OUT" | jq -cR 'fromjson? | .. | objects | (.function_response // .functionResponse // empty)
  | (.response // {}) | (if (.result|type) == "object" then .result else . end) | select(type == "object" and has("status"))
  | {status: .status, error: ((.error // "") | tostring | .[0:200])}' 2>/dev/null | head -1)"
ST=""; [[ -n "$FR" ]] && ST="$(jq -r '.status | if . == null then "null" else tostring end' <<<"$FR")"
if [[ "$ST" == 200 || "$ST" == 401 ]]; then CL="$ST"; WHERE=tool
elif grep -Eq 'UNAUTHENTICATED|Context-Aware Access requirements are not met|"code": ?401|401 Unauthorized' "$LZV_LAST_OUT"; then CL=401; WHERE=stream
else CL=other; WHERE=none; fi
note "agent G call: class=$CL where=$WHERE detail=${FR:-no tool result}"

DAY="$(date -u +%F)"
case "$CL" in
  401) V=PASS; W="" ;;
  200) V=FAIL; W="the run-6 401 did not reproduce on $DAY; cause unknown" ;;
  *)   V=INCONCLUSIVE; W="no 401 and no 200 (${FR:-no tool result})" ;;
esac
write_result "$V" Enforced "call through the gateway: $CL (where=$WHERE); iapPolicyVersion=$IAPV; versions: $G_VERSIONS" "$W"
