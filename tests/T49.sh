#!/usr/bin/env bash
# T49 (v3 B10): replay of a bound token used on the Agent Gateway path. Plan: plans/v3-harness-boundary-tests.md T49
# (added 2026-11-11 after F3, before any T49 run).
# Engines: agent G (lzv-probe-g, default binding, egress only through Agent Gateway) and G-optout (lzv-probe-g-optout),
# the T47 engines. Tool replay_check("gateway") in tests/fixtures/gateway/agent_g/agent.py, inside the agent:
#   s1  the T47 s2 call (regular aiplatform host, no client certificate, through the gateway) with the agent's own token;
#       records status, the binding state google-auth reports, token SHA-256 prefix and expiry; observation: the same
#       call on the mTLS host with the client certificate.
#   s2  the same token goes, in memory, to the replay service (tests/fixtures/replay, Cloud Run in another project, no
#       agent certificate), which calls the same Vertex AI endpoint with the same payload.
# Stages: bound (G: s1 + s2) | optout (G-optout: s1 + s2 = s3 of the plan, the control that the replay path works).
# The result is written by optout. Tokens never reach this script or the evidence (only the SHA-256 prefix and expiry).
# Preconditions: infra/ v3h_replay_register_on_gateway=true (replay host in the Agent Registry; the gateway allows only
# registered hosts), agent G deployed with LZV_REPLAY_URL, perimeter not enforced on the runtime project (as T48).
# Falsified if: the bound gateway-path token is accepted on replay (200).
# shellcheck disable=SC2016
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib-v3h.sh
source "$(dirname "$0")/lib-v3h.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in bound|optout) ;; *) lzv_die "usage: T49.sh bound|optout" ;; esac

RT="$(project_id runtime)"
LZV_SCOPE="projects/$RT"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/agent-identity"
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/troubleshooting/runtime-setup"
  "https://docs.cloud.google.com/access-context-manager/docs/caa-agent-security"
)
header T49 "B10 (Enforced)" "Replay, from a different workload, of a bound agent token that was used on the Agent Gateway path; controls: the agent's gateway call 200, replay service with operator credentials 200, opt-out token replay 200" \
  "s1: the bound agent's own call through the gateway returns 200 (T47 s2 reproduced). s2: the same token replayed from the replay service (other project, no agent certificate) against the same endpoint and payload is refused with 401 UNAUTHENTICATED: the token taken on the gateway path is bound and binding is enforced on the replay. s3 (stage optout, G-optout): replay 200. Falsified if: s2 returns 200 (a token used on the gateway path is replayable from another workload). INCONCLUSIVE if: the s3 replay is not 200, s1 is not 200, either replay returns 403 (fixture IAM), or the replay request cannot reach the service through the gateway egress policy. Tier: Enforced. 3 runs." \
  "$STAGE"
note "plan claim B10; no resources are created by this script; no cleanup_trap registered"
note "limitation (as T48): a 401 from a workload without a certificate does not distinguish 'no certificate' from 'wrong certificate'"
GA_REQ="$(grep -hE '^google-auth' "$LZV_ROOT/tests/fixtures/gateway/agent_g/requirements.txt" 2>/dev/null | head -1)"
note "agent G requirements: ${GA_REQ:-google-auth not pinned}"
[[ -f "$LZV_ROOT/infra/agents/build/source-g.tar.gz" ]] && note "agent G tarball sha256: $(shasum -a 256 "$LZV_ROOT/infra/agents/build/source-g.tar.gz" | cut -c1-16)..."

REGION="$LZV_REGION"
AID_G="$(agents_tf '.agent_g.value.id' 2>/dev/null)" || AID_G=""
AID_GO="$(agents_tf '.agent_g_optout.value.id' 2>/dev/null)" || AID_GO=""
if [[ "$STAGE" == optout ]]; then
  [[ -n "$AID_GO" && "$AID_GO" != null ]] || guard_abort "deploy agent G-optout first (infra/agents deploy_agent_g_optout=true)"
  AID="$AID_GO"
else
  [[ -n "$AID_G" && "$AID_G" != null ]] || guard_abort "deploy agent G first (infra/agents deploy_agent_g=true)"
  AID="$AID_G"
fi
[[ "$STAGE" == bound ]] || [[ "$(read_stage bound)" != MISSING ]] || guard_abort "run stage bound first (same RUN_ID)"

v3h_engine_env "$AID"
G_CREATED="$(v3h_json_last | jq -r '.createTime // empty' 2>/dev/null)"
[[ -z "$G_CREATED" ]] || v3h_g_versions "$G_CREATED"   # plan 3b: versions recorded in every T47/T49 result (note only)
OPTED="$(jq -r '((.GOOGLE_API_ENABLE_RUNTIME_BOUND_TOKEN // "") | ascii_downcase) == "false" | if . then 1 else 0 end' <<<"$V3H_ENV_JSON")"
ENV_READ="$(jq -r 'length' <<<"$V3H_ENV_JSON")"
WANT_OPT=0; [[ "$STAGE" == optout ]] && WANT_OPT=1
if [[ "$ENV_READ" != 0 && "$OPTED" != "$WANT_OPT" ]]; then
  guard_abort "stage $STAGE needs opt-out=$WANT_OPT on $AID, found $OPTED"
fi
[[ "$ENV_READ" != 0 ]] || note "engine env could not be read; relying on the Terraform variables"
REPLAY_URL="$(jq -r '.LZV_REPLAY_URL // empty' <<<"$V3H_ENV_JSON")"
[[ "$ENV_READ" == 0 || "$REPLAY_URL" == https://* ]] || guard_abort "agent has no LZV_REPLAY_URL (infra/agents agent_v3_replay_url)"
REPLAY_URL="${REPLAY_URL:-${V3H_REPLAY_URL:-}}"
[[ "$REPLAY_URL" == https://* ]] || guard_abort "no replay service URL"
[[ "$REPLAY_URL" != *"$RT"* ]] || note "WARNING: the replay URL contains the runtime project id; it must be a different project"
note "agent: $AID; replay service: $REPLAY_URL"

# Replay host registered on the gateway (the only way G reaches it). Read-only check of the infra/ output.
REG="$(terraform -chdir="$LZV_ROOT/infra" state list 2>/dev/null | grep -cF 'module.v2_agent_registry.google_agent_registry_service.default["lzv-ep-v3h-replay"]')"   # run 10: Fabric geap-agent-registry address
[[ "$REG" == 1 ]] || note "replay host registry entry not in infra/ state (v3h_replay_register_on_gateway): the replay is expected to be refused by the gateway"

# Perimeter: the replay comes from outside the perimeter; enforced status would refuse it before binding (as T48).
RT_NUM="$(project_number runtime)"
run_capture gcloud access-context-manager policies list --organization="$(org_id)" --format=json
POL="$(v3h_json_last | jq -r --arg f "folders/$(folder_id root)" '[.[] | select((.scopes // []) | index($f))][0].name // empty' | sed 's#^accessPolicies/##')"
[[ -n "$POL" ]] || guard_abort "no access policy scoped to the test folder"
run_capture gcloud access-context-manager perimeters describe lzv_ai --policy="$POL" --format=json
IN_STATUS="$(v3h_json_last | jq -r --arg p "projects/$RT_NUM" '[(.status.resources // [])[] | select(. == $p)] | length')"
[[ "$IN_STATUS" == 0 ]] || guard_abort "runtime project is in the ENFORCED perimeter; T49 needs dry-run (as T48)"

EMPTY_JSON="{}"
MODEL="$(jq -r '.LZV_MODEL // "gemini-3.5-flash"' <<<"$V3H_ENV_JSON")"

# Control 2: replay service with the operator's own credentials (token built inside the quoted command, never logged)
export LZV_REPLAY_URL="$REPLAY_URL" LZV_PROJECT="$RT" LZV_MODEL_NAME="$MODEL"
run_capture_sh 'jq -cn --arg t "$(gcloud auth print-access-token)" --arg p "$LZV_PROJECT" --arg m "$LZV_MODEL_NAME" "{token:\$t,project:\$p,model:\$m,location:\"global\"}" | curl -sS --max-time 90 -H "Authorization: Bearer $(gcloud auth print-identity-token)" -H "Content-Type: application/json" -X POST "$LZV_REPLAY_URL/replay" -d @- -w "\nHTTP %{http_code}\n"'
CTL_JSON="$(grep -E '^\{' "$LZV_LAST_OUT" | head -1)"
CTL_STATUS="$(jq -r '(.status // "none") | tostring' <<<"${CTL_JSON:-$EMPTY_JSON}" 2>/dev/null || echo none)"
note "control 2 (replay service, operator token): vertex status=$CTL_STATUS"

# The agent query (LLM agent G calls the fixed tool; the tool result is read from the function response)
export LZV_URL="https://${REGION}-aiplatform.googleapis.com/v1/${AID}:streamQuery?alt=sse"
LZV_BODY="$(jq -cn '{class_method:"async_stream_query", input:{user_id:"lzv-t49", message:"Call replay_check with mode \"gateway\". Reply with the tool result."}}')"
export LZV_BODY
run_capture_sh 'printf "Authorization: Bearer %s\n" "$(gcloud auth print-access-token)" | curl -sS -N --max-time 240 -H @- -H "Content-Type: application/json" -X POST "$LZV_URL" -d "$LZV_BODY" -w "\nHTTP %{http_code}\n" 2>&1'
R="$(sed 's/^data: *//' "$LZV_LAST_OUT" | jq -cR 'fromjson? | .. | objects | (.function_response // .functionResponse // empty)
  | select((.name // "") == "replay_check") | (.response // {}) | (if (.result|type) == "object" then .result else . end)
  | select(type == "object" and has("mode"))' 2>/dev/null | head -1)"
HAVE=0; [[ -n "$R" ]] && HAVE=1
R="${R:-$EMPTY_JSON}"
g() { jq -r "$1 | if . == null then \"none\" else tostring end" <<<"$R"; }   # keeps false (jq // drops it)
OWN="$(g .own_gw_status)"; MTLS="$(g .own_mtls_status)"; RH="$(g .replay_http_status)"; RS="$(g .replay.status)"
SHA12="$(g .token_sha12)"; EXP="$(g .token_expiry)"; ERR="$(g .error)"
BIND="google-auth=$(g .google_auth) agent_cert=$(g .agent_cert_present) should_request_bound=$(g .should_request_bound_token) env_runtime_bound=$(g .env_runtime_bound)$( [[ "$(g .binding_probe_error)" != none ]] && echo " probe_error=$(g .binding_probe_error)")"
RERR="$(jq -r '((.replay.error_status // "") + " " + (.replay.error_message // "")) | .[0:300]' <<<"$R")"
note "tool result present=$HAVE; s1 own call through the gateway=$OWN; observation mTLS host=$MTLS (is_mtls=$(g .own_mtls)$( [[ "$(g .own_mtls_error)" != none ]] && echo ", error=$(g .own_mtls_error)"))"
note "binding state in the agent: $BIND"
note "s2 replay: service HTTP=$RH replayed status=$RS token sha12=$SHA12 expiry=$EXP; replay error: ${RERR:- none}; tool error: $ERR"

# gateway log (observation): the replay POST to the run.app host and the model calls
sleep 45
SINCE="$(date -u -v-3M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-3 min' +%Y-%m-%dT%H:%M:%SZ)"
run_capture gcloud logging read "timestamp>=\"$SINCE\" AND logName=\"projects/$RT/logs/networkservices.googleapis.com%2Fgateway_requests\"" --project="$RT" --limit=200 --format=json
note "gateway log (observation): $(v3h_json_last | jq -r '[.[] | select((.httpRequest.requestUrl // "") | test("run\\.app"))] | length') run.app records, $(v3h_json_last | jq -r '[.[] | select((.httpRequest.requestUrl // "") | test("generateContent"))] | length') decoded generateContent records, $(v3h_json_last | jq -r '[.[] | select(.httpRequest.requestMethod == "CONNECT")] | length') CONNECT records in the last 3 min"

V=INCONCLUSIVE; W=""
if [[ "$HAVE" != 1 ]]; then W="no replay_check result from the agent"
elif [[ "$OWN" == 403 || "$RS" == 403 || "$CTL_STATUS" == 403 ]]; then W="403 seen (own=$OWN replay=$RS control=$CTL_STATUS): fixture IAM error"
elif [[ "$OWN" != 200 ]]; then W="s1 failed: the agent's own call through the gateway returned $OWN"
elif [[ "$CTL_STATUS" != 200 ]]; then W="control 2 failed: replay service with operator credentials gave $CTL_STATUS"
elif [[ "$RH" != 200 ]]; then W="the replay request did not reach the service through the gateway (HTTP $RH; $ERR)"
elif [[ "$STAGE" == bound ]]; then
  case "$RS" in
    401) V=PASS ;;
    200) V=FAIL; W="bound token used on the gateway path accepted on replay from another workload (200): binding does not protect behind the gateway (finding)" ;;
    *)   W="bound replay returned status $RS" ;;
  esac
else
  case "$RS" in
    200) V=PASS ;;
    *)   W="opt-out replay returned $RS: replay path control failed" ;;
  esac
fi
write_stage "$V" "$STAGE: s1 own(gateway)=$OWN mTLS-host=$MTLS control2=$CTL_STATUS replay=$RS sha12=$SHA12; $BIND${W:+; $W}"

if [[ "$STAGE" == optout ]]; then
  SB="$(read_stage bound)"
  # A bound replay accepted (FAIL) stands on its own: the 200 itself shows the replay path works.
  # Otherwise the bound 401 counts only with the opt-out control passing.
  if [[ "$SB" == FAIL ]]; then FINAL=FAIL
  elif [[ "$V" != PASS ]]; then FINAL=INCONCLUSIVE
  else FINAL="$SB"; fi
  WHY=""
  [[ "$SB" == PASS ]] || WHY+="stage bound: $SB ($(jq -r '.note // empty' "$LZV_DIR/stages/bound.json" 2>/dev/null)); "
  [[ "$V" == PASS ]] || WHY+="stage optout: $W; "
  [[ "$FINAL" == PASS ]] && WHY=""
  write_result "$FINAL" Enforced "bound: $(jq -r '.note' "$LZV_DIR/stages/bound.json"); optout: own=$OWN control2=$CTL_STATUS replay=$RS sha12=$SHA12" "$WHY"
fi
