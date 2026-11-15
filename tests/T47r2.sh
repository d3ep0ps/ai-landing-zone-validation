#!/usr/bin/env bash
# T47r2 (v3 B8 regression, 1 attempt, conditional): the run-6 package set. Plan: plans/v3-harness-boundary-tests.md
# section 3b (pre-registered 2026-11-12, commit 6fb4740, before this script). As T47r (IAP V1, no gateway VPC, default
# binding, one T47 s2 call), but agent G is built from requirements-run6.txt (aiplatform 2.6.0, google-genai 2.33.0,
# google-auth 2.62.0, google-adk 2.13.0: the latest PyPI uploads before run 6). Agent G's code is the current fixture.
# Gate: the latest T49 `bound` stage shows agent_cert=true, should_request_bound=true and replay=401 (G's token is bound
# behind the gateway). Not met -> NOT_TESTED, no cloud call.
# No prediction: 401 (query or session POST) -> client-side cause (H3); 200 with the session POST 200 in the gateway log ->
# Google-side cause (H1). PASS = the test discriminated (either clean outcome); INCONCLUSIVE otherwise.
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
  "https://docs.cloud.google.com/access-context-manager/docs/caa-agent-security"
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/agent-gateway-runtime-deploy"
)
header T47r2 "B8 regression (Enforced, 1 attempt, conditional)" "T47r with agent G pinned to the run-6 package set; gate: T49 shows G's token bound behind the gateway" \
  "No prediction (discriminating test). 401 on the session call or the query: the run-6 401 reproduces with the run-6 packages; cause client-side (H3), first candidate google-auth 2.62.0 vs 2.62.1. 200 with the session POST 200 in the gateway log: the run-6 401 does not reproduce even with the run-6 packages; cause Google-side (H1). PASS = clean outcome either way; INCONCLUSIVE otherwise. Limitation: agent G code is the current fixture, not run 6's. Tier: Enforced (1 attempt). Paid: gateway hours; same-day teardown." \
  ""
note "plan B8 regression (H1 vs H3, notes/run6-401-analysis.md); no resources are created by this script; no cleanup_trap registered"

# --- gate: T49 bound stage (latest run)
T49J="$(ls -t "$LZV_ROOT"/evidence/T49/run-*/stages/bound.json 2>/dev/null | head -1)"
T49N="$( [[ -n "$T49J" ]] && jq -r '.note // ""' "$T49J")"
note "gate source: ${T49J#"$LZV_ROOT/"} -> ${T49N:0:300}"
shopt -s nocasematch
if [[ -z "$T49J" || "$T49N" != *"agent_cert=true"* || "$T49N" != *"should_request_bound=true"* || "$T49N" != *"replay=401"* ]]; then
  shopt -u nocasematch
  write_result NOT_TESTED Enforced "gate not met: T49 bound stage ${T49J:+found}${T49J:-missing}" "T47r2 runs only if T49 shows G's token bound (agent_cert, should_request_bound, replay 401); otherwise H2 (unbound token) explains the November 200s"
  exit 0
fi
shopt -u nocasematch

PKG="$LZV_ROOT/infra/agents/build/source-g-run6.tar.gz"
[[ -f "$PKG" ]] || guard_abort "build the run-6 agent G tarball first (VARIANT=run6 agent_g/build.sh)"
note "run-6 tarball sha256 $(shasum -a 256 "$PKG" | cut -c1-16)...; requirements: $(tar -xzOf "$PKG" requirements.txt | tr '\n' ' ')"

REGION="$LZV_REGION"
AID_G="$(agents_tf '.agent_g.value.id' 2>/dev/null)" || AID_G=""
[[ -n "$AID_G" && "$AID_G" != null ]] || guard_abort "deploy agent G first (agent_g_run6=true)"
run_capture gcloud alpha network-services agent-gateways describe lzv-gw --location="$REGION" --project="$RT" --format=json
[[ "$LZV_LAST_RC" == 0 ]] || guard_abort "agent gateway lzv-gw not found in $REGION"
IAPV="$(v3h_json_last | jq -r '[.. | objects | .iapPolicyVersion? // empty] | first // "not shown"' 2>/dev/null)"
[[ "$IAPV" != V2 ]] || guard_abort "the gateway uses IAP policy V2; T47r2 needs V1 (infra/profiles/v3h-t47r.tfvars)"
v3h_engine_env "$AID_G"
CREATED="$(v3h_json_last | jq -r '.createTime // empty' 2>/dev/null)"
[[ "$(jq -r '((.GOOGLE_API_ENABLE_RUNTIME_BOUND_TOKEN // "") | ascii_downcase) == "false"' <<<"$V3H_ENV_JSON")" == false ]] \
  || guard_abort "agent G has the token-binding opt-out; T47r2 needs the default binding"
v3h_g_versions "${CREATED:-$(date -u -v-3H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-3 hour' +%Y-%m-%dT%H:%M:%SZ)}"
[[ "$G_VERSIONS" == *"google-auth=2.62.0"* ]] || note "WARNING: resolved google-auth is not 2.62.0 ($G_VERSIONS)"

T0="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export LZV_URL="https://${REGION}-aiplatform.googleapis.com/v1/${AID_G}:streamQuery?alt=sse"
LZV_BODY="$(jq -cn '{class_method:"async_stream_query", input:{user_id:"lzv-t47r2", message:"Call call_model with endpoint \"allowed\". Reply with the tool result."}}')"
export LZV_BODY
run_capture_sh 'printf "Authorization: Bearer %s\n" "$(gcloud auth print-access-token)" | curl -sS -N --max-time 240 -H @- -H "Content-Type: application/json" -X POST "$LZV_URL" -d "$LZV_BODY" -w "\nHTTP %{http_code}\n" 2>&1'
FR="$(sed 's/^data: *//' "$LZV_LAST_OUT" | jq -cR 'fromjson? | .. | objects | (.function_response // .functionResponse // empty)
  | (.response // {}) | (if (.result|type) == "object" then .result else . end) | select(type == "object" and has("status"))
  | {status: .status, error: ((.error // "") | tostring | .[0:200])}' 2>/dev/null | head -1)"
ST=""; [[ -n "$FR" ]] && ST="$(jq -r '.status | if . == null then "null" else tostring end' <<<"$FR")"
if [[ "$ST" == 200 || "$ST" == 401 ]]; then CL="$ST"; WHERE=tool
elif grep -Eq 'UNAUTHENTICATED|Context-Aware Access requirements are not met|"code": ?401|401 Unauthorized|invalid authentication credentials' "$LZV_LAST_OUT"; then CL=401; WHERE=stream
else CL=other; WHERE=none; fi
note "agent G query: class=$CL where=$WHERE detail=${FR:-no tool result}"

sleep 60   # gateway logs arrive with a delay
run_capture gcloud logging read "timestamp>=\"$T0\" AND logName=\"projects/$RT/logs/networkservices.googleapis.com%2Fgateway_requests\"" --project="$RT" --limit=200 --format=json
SESS="$(v3h_json_last | jq -r '[.[] | select((.httpRequest.requestUrl // "") | test("reasoningEngines/[0-9]+/sessions")) | select(.httpRequest.requestMethod == "POST") | .httpRequest.status] | group_by(.) | map("\(.[0])x\(length)") | join(",")' 2>/dev/null)"
IAMC="$(v3h_json_last | jq -r '[.[] | select((.httpRequest.requestUrl // "") | test("iamcredentials")) | .httpRequest.status] | group_by(.) | map("\(.[0])x\(length)") | join(",")' 2>/dev/null)"
TLSI="$(v3h_json_last | jq -r '[.[] | .jsonPayload.enforcedGatewaySecurityPolicy.requestWasTlsIntercepted // empty] | unique | join(",")' 2>/dev/null)"
note "gateway log since $T0: session POST status=${SESS:-none}; iamcredentials status=${IAMC:-none}; TLS intercepted=${TLSI:-?}"

V=INCONCLUSIVE; W=""; READ=""
if [[ "$CL" == 401 || "$SESS" == *"401x"* ]]; then V=PASS; READ="the run-6 401 reproduces with the run-6 package set: client-side cause (H3); first candidate google-auth 2.62.0 vs 2.62.1"
elif [[ "$CL" == 200 && "$SESS" == *"200x"* ]]; then V=PASS; READ="the run-6 401 does not reproduce with the run-6 package set either: Google-side cause (H1), no longer reproducible"
else W="no clean outcome (query=$CL, session POST=${SESS:-none})"; fi
[[ -n "$READ" ]] && note "reading: $READ"
write_result "$V" Enforced "query=$CL (where=$WHERE); session POST=${SESS:-none}; iamcredentials=${IAMC:-none}; iapPolicyVersion=$IAPV; versions: $G_VERSIONS${READ:+; reading: $READ}" "$W"
