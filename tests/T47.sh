#!/usr/bin/env bash
# T47 (v3 B8): isolate the cause of the gateway 401, one variable at a time. Plan: plans/v3-harness-boundary-tests.md T47.
# Variable: infra/agents agent_g_caa_token_binding_opt_out (DEFAULT IS TRUE, so the baseline must start by setting it
# false: stage s1 guards that the deployed engine has no opt-out). Known baseline: gateway VPC egress on, IAP policy v2,
# pinned packages (google-auth recorded below). Stages and human steps (one agent deploy per apply, 30 minutes apart):
#   s1  agent G deployed with agent_g_caa_token_binding_opt_out=false; control: agent v3a (default binding, NOT behind the
#       gateway, infra/agents agent_v3) model call -> expect 200
#   s2  binding default, through the gateway (agent G, call_model "allowed") -> expect 401
#   (human: agent_g_caa_token_binding_opt_out=true, apply; wait 4 minutes after the deploy)
#   s3  opt-out, through the gateway -> expect 200
#   (human: agent_g_caa_token_binding_opt_out=false, apply, wait 4 minutes)
#   s4  back to default, through the gateway -> expect 401; writes the result
# Interpretation choice: the plan's "direct (no gateway)" step has no agent-G toggle (G is always bound to the gateway), so
# the direct control is the v3a agent from the same fixture family, same model endpoint, binding default.
# A 401 may surface as the tool result of G or as a failure of G's own model call in the stream; both are recorded
# (where=tool|stream). Falsified if: step 2 succeeds or step 4 succeeds (then the 401 was not caused by binding alone).
# shellcheck disable=SC2016
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib-v3h.sh
source "$(dirname "$0")/lib-v3h.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in s1|s2|s3|s4) ;; *) lzv_die "usage: T47.sh s1|s2|s3|s4" ;; esac

RT="$(project_id runtime)"
LZV_SCOPE="projects/$RT"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/agent-identity"
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/troubleshooting/runtime-setup"
  "https://docs.cloud.google.com/access-context-manager/docs/caa-agent-security"
  "https://github.com/googleapis/python-aiplatform/issues/7209"
)
header T47 "B8 (Enforced)" "Gateway 401 caused by certificate-bound tokens alone; control: one variable changed per step (token binding), gateway on/off as in the table" \
  "Step 1: default (bound), no gateway (direct): 200 (control). Step 2: default (bound), through gateway: 401. Step 3: opt-out, through gateway: 200. Step 4: back to default, through gateway: 401. Falsified if: step 2 succeeds or step 4 succeeds (then the 401 wasn't caused by binding alone, and the article must say so). Tier: Enforced. 3 runs. From run 2 (plans/v3h-automation.md, approved before the run): step 3 runs on a second gateway-bound engine with the opt-out (lzv-probe-g-optout, same tarball) deployed side by side; step 4 repeats step 2 on the bound engine (lzv-probe-g) without a redeploy." \
  "$STAGE"
note "plan claim B8; no resources are created by this script; no cleanup_trap registered"
GA_REQ="$(grep -hE '^google-auth' "$LZV_ROOT/tests/fixtures/gateway/agent_g/requirements.txt" 2>/dev/null | head -1)"
note "agent G requirements: ${GA_REQ:-google-auth not pinned} (opt-out env var semantics: GOOGLE_API_ENABLE_RUNTIME_BOUND_TOKEN takes precedence from google-auth 2.59)"
[[ -f "$LZV_ROOT/infra/agents/build/source-g.tar.gz" ]] && note "agent G tarball sha256: $(shasum -a 256 "$LZV_ROOT/infra/agents/build/source-g.tar.gz" | cut -c1-16)..."

REGION="$LZV_REGION"
AID_G="$(agents_tf '.agent_g.value.id' 2>/dev/null)" || AID_G=""
AID_A="$(agents_tf '.agent_v3.value.a.id' 2>/dev/null)" || AID_A=""
[[ -n "$AID_G" ]] || guard_abort "deploy agent G first (infra/agents deploy_agent_g=true)"
# Run 2+: step 3 uses the side-by-side opt-out engine when it is deployed.
AID_GO="$(agents_tf '.agent_g_optout.value.id' 2>/dev/null)" || AID_GO=""
if [[ "$STAGE" == s3 && -n "$AID_GO" && "$AID_GO" != null ]]; then AID_G="$AID_GO"; note "step 3 on the side-by-side opt-out engine lzv-probe-g-optout"; fi
run_capture gcloud alpha network-services agent-gateways describe lzv-gw --location="$REGION" --project="$RT"
[[ "$LZV_LAST_RC" == 0 ]] || guard_abort "agent gateway lzv-gw not found in $REGION"
note "agent G: $AID_G; direct control agent v3a: ${AID_A:-not deployed}"

# binding state of the deployed engine (env names read from the API; soft check if unreadable)
v3h_engine_env "$AID_G"
G_CREATED="$(v3h_json_last | jq -r '.createTime // empty' 2>/dev/null)"
[[ -z "$G_CREATED" ]] || v3h_g_versions "$G_CREATED"   # plan 3b: versions recorded in every T47/T49 result (note only)
OPTED="$(jq -r '((.GOOGLE_API_ENABLE_RUNTIME_BOUND_TOKEN // "") | ascii_downcase) == "false" | if . then 1 else 0 end' <<<"$V3H_ENV_JSON")"
ENV_READ="$(jq -r 'length' <<<"$V3H_ENV_JSON")"
note "agent G opt-out env set=$OPTED (env fields read=$ENV_READ)"
WANT_OPT=0; [[ "$STAGE" == s3 ]] && WANT_OPT=1
if [[ "$ENV_READ" != 0 && "$OPTED" != "$WANT_OPT" ]]; then
  guard_abort "stage $STAGE needs opt-out=$WANT_OPT on agent G (agent_g_caa_token_binding_opt_out), found $OPTED"
fi
[[ "$ENV_READ" != 0 ]] || note "engine env could not be read; relying on the Terraform variable being set as the stage requires"

# query_g MESSAGE -> G_CLASS (200|401|other), G_WHERE, G_DETAIL
query_g() {
  local frs st
  export LZV_URL="https://${REGION}-aiplatform.googleapis.com/v1/${AID_G}:streamQuery?alt=sse"
  LZV_BODY="$(jq -cn --arg m "$1" '{class_method:"async_stream_query", input:{user_id:"lzv-t47", message:$m}}')"
  export LZV_BODY
  run_capture_sh 'out="$(printf "Authorization: Bearer %s\n" "$(gcloud auth print-access-token)" | curl -sS -N --max-time 240 -H @- -H "Content-Type: application/json" -X POST "$LZV_URL" -d "$LZV_BODY" -w "\nHTTP %{http_code}\n" 2>&1)"; printf "%s\n" "$out"; case "$out" in *$'"'"'\n'"'"'HTTP\ 200) exit 0 ;; esac; exit 1'
  frs="$(sed 's/^data: *//' "$LZV_LAST_OUT" | jq -cR 'fromjson? | .. | objects | (.function_response // .functionResponse // empty)
    | (.response // {}) | (if (.result|type) == "object" then .result else . end)
    | select(type == "object" and has("status"))
    | {status: .status, error: ((.error // "") | tostring | .[0:200])}' 2>/dev/null | head -1)"
  st=""; [[ -n "$frs" ]] && st="$(jq -r '.status | if . == null then "null" else tostring end' <<<"$frs")"
  G_WHERE=none; G_DETAIL="${frs:-no tool result}"
  if [[ "$st" == 200 ]]; then G_CLASS=200; G_WHERE=tool
  elif [[ "$st" == 401 ]]; then G_CLASS=401; G_WHERE=tool
  elif grep -Eq 'UNAUTHENTICATED|Context-Aware Access requirements are not met|"code": ?401|401 Unauthorized' "$LZV_LAST_OUT"; then
    G_CLASS=401; G_WHERE=stream; G_DETAIL="$(grep -Eo 'UNAUTHENTICATED|Context-Aware Access requirements are not met|"code": ?401' "$LZV_LAST_OUT" | sort -u | tr '\n' ' ')"
  else G_CLASS=other; fi
  note "agent G call: class=$G_CLASS where=$G_WHERE detail=$G_DETAIL"
}
G_MSG='Call call_model with endpoint "allowed". Reply with the tool result.'

# gw_log_note: observation only (F3 in run 1): how the gateway logged the last minute of G's traffic,
# decoded aiplatform POSTs vs CONNECT tunnels. Read-only; not part of the verdict.
gw_log_note() {
  local since; sleep 45  # gateway logs arrive with a delay
  since="$(date -u -v-2M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-2 min' +%Y-%m-%dT%H:%M:%SZ)"
  run_capture gcloud logging read "timestamp>=\"$since\" AND logName=\"projects/$RT/logs/networkservices.googleapis.com%2Fgateway_requests\"" \
    --project="$RT" --limit=100 --format=json
  note "gateway log (observation): $(v3h_json_last | jq -r '[.[] | select((.httpRequest.requestUrl // "") | test("generateContent"))] | length') decoded generateContent records, $(v3h_json_last | jq -r '[.[] | select(.httpRequest.requestMethod == "CONNECT")] | length') CONNECT records in the last 2 min"
}

case "$STAGE" in
s1)
  if [[ -z "$AID_A" ]]; then
    write_stage INCONCLUSIVE "s1: no direct control agent (deploy v3a: infra/agents deploy_agent_v3a=true, agent_v3_token_binding_opt_out=false)"
  else
    v3h_query "$AID_A" "ACTION=model MODE=bypass"
    if [[ "$Q_STATUS" == 200 && "$Q_BY" == none ]]; then write_stage PASS "s1: direct control (v3a, default binding, no gateway) status 200"
    else write_stage INCONCLUSIVE "s1: direct control not 200 (status=$Q_STATUS refused_by=$Q_BY err=${Q_ERR:-none})"; fi
  fi
  ;;
s2|s4)
  query_g "$G_MSG"
  gw_log_note
  case "$G_CLASS" in
    401) write_stage PASS "$STAGE: bound token through the gateway: 401 (where=$G_WHERE, $G_DETAIL)" ;;
    200) write_stage FAIL "$STAGE: bound token through the gateway succeeded (200): the 401 is not caused by binding alone" ;;
    *)   write_stage INCONCLUSIVE "$STAGE: no 401 and no 200 ($G_DETAIL)" ;;
  esac
  ;;
s3)
  query_g "$G_MSG"
  gw_log_note
  case "$G_CLASS" in
    200) write_stage PASS "s3: opt-out through the gateway: 200 (where=$G_WHERE)" ;;
    401) write_stage FAIL "s3: opt-out through the gateway still 401 (where=$G_WHERE, $G_DETAIL): binding alone does not explain the 401" ;;
    *)   write_stage INCONCLUSIVE "s3: no 200 and no 401 ($G_DETAIL)" ;;
  esac
  ;;
esac

if [[ "$STAGE" == s4 ]]; then
  S1="$(read_stage s1)"; S2="$(read_stage s2)"; S3="$(read_stage s3)"; S4="$(read_stage s4)"
  S1="${S1/MISSING/INCONCLUSIVE}"; S2="${S2/MISSING/INCONCLUSIVE}"; S3="${S3/MISSING/INCONCLUSIVE}"
  FINAL="$(verdict_merge "$S1" "$S2" "$S3" "$S4")"
  # without a working direct control the 401s prove nothing about binding
  [[ "$S1" == PASS || "$FINAL" == FAIL ]] || FINAL=INCONCLUSIVE
  WHY=""
  for p in s1 s2 s3 s4; do
    sv="$(read_stage "$p")"
    [[ "$sv" == PASS ]] || WHY+="$p: $sv ($(jq -r '.note // empty' "$LZV_DIR/stages/$p.json" 2>/dev/null)); "
  done
  [[ "$FINAL" == PASS ]] && WHY=""
  ACT="s1=$S1 s2=$S2 s3=$S3 s4=$S4; ${GA_REQ:-google-auth unpinned}"
  write_result "$FINAL" Enforced "$ACT" "$WHY"
fi
