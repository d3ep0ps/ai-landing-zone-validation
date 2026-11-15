#!/usr/bin/env bash
# T48 (v3 B9): what the opt-out costs: token replay across workloads. Plan: plans/v3-harness-boundary-tests.md T48.
# Uses agent v3a (infra/agents agent_v3) with ACTION=replay: inside the agent one Vertex AI generateContent call is made with
# its own credentials, then the bearer token goes IN MEMORY, agent -> replay service (tests/fixtures/replay, Cloud Run in
# ANOTHER project, auth required), which calls the same endpoint with the same payload. Tokens are never written anywhere:
# only the SHA-256 prefix and expiry returned by the agent are kept. No token reaches this script.
# Stages (human steps between): bound (agent_v3_token_binding_opt_out=false, default binding) | optout
# (agent_v3_token_binding_opt_out=true, apply, wait 4 minutes). The replay service must be deployed first and its URL set
# in agent_v3_replay_url (or exported as V3H_REPLAY_URL); the result is written by `optout`.
# Controls per stage: (1) the agent's own call status must be 200 in both modes; (2) a replay-service positive control with
# the OPERATOR's own credentials must be 200 (proves endpoint and payload); (3) any 403 = fixture IAM error -> INCONCLUSIVE.
# Reading a 401: a workload without the agent's certificate shows "token not usable without the agent's certificate", not
# "wrong certificate" (the Cloud Run job has no client certificate at all); the doc check could not separate the two causes.
# Falsified if: the bound token returns 200 from the second workload, or the opt-out token returns 401, or either returns 403.
# shellcheck disable=SC2016
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib-v3h.sh
source "$(dirname "$0")/lib-v3h.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in bound|optout) ;; *) lzv_die "usage: T48.sh bound|optout" ;; esac

RT="$(project_id runtime)"
LZV_SCOPE="projects/$RT"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/agent-identity"
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/troubleshooting/runtime-setup"
  "https://docs.cloud.google.com/access-context-manager/docs/caa-agent-security"
)
header T48 "B9 (Enforced)" "Replay of an agent bearer token from a different workload against the same Vertex AI endpoint and payload; control: agent's own call 200, replay service with operator credentials 200" \
  "With default token binding (GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES unset/true): expected refused (401 UNAUTHENTICATED) when replayed from the second workload, even though IAM allows the principal. With the gateway opt-out (GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=False): expected accepted (200 OK) when replayed from the second workload. Falsified if: the bound token returns 200 OK from the second workload (which would prove binding isn't enforced on Vertex AI calls), or the opt-out token returns 401, or either returns 403 (fixture IAM error). Tier: Enforced. From run 2 (plans/v3h-automation.md, approved before the run): the optout stage runs on a side-by-side engine with the opt-out (lzv-v3-o, same tarball as v3a) instead of redeploying v3a." \
  "$STAGE"
note "plan claim B9; no resources are created by this script (agents and the replay service are deployed by the human); no cleanup_trap registered"
note "the opt-out is applied with BOTH variables (agent_v3_token_binding_opt_out sets GOOGLE_API_ENABLE_RUNTIME_BOUND_TOKEN=false and the deprecated GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=False; google-auth 2.62.1 pinned)"
note "limitation: a 401 from a workload without a certificate does not distinguish 'no certificate' from 'wrong certificate'"

AID_A="$(agents_tf '.agent_v3.value.a.id' 2>/dev/null)" || AID_A=""
[[ -n "$AID_A" ]] || guard_abort "deploy agent v3a first (infra/agents deploy_agent_v3a=true)"
# Run 2+: the optout stage uses the side-by-side opt-out engine when it is deployed.
AID_O="$(agents_tf '.agent_v3.value.o.id' 2>/dev/null)" || AID_O=""
if [[ "$STAGE" == optout && -n "$AID_O" && "$AID_O" != null ]]; then AID_A="$AID_O"; note "optout stage on the side-by-side engine lzv-v3-o"; fi
v3h_engine_env "$AID_A"
OPTED="$(jq -r '((.GOOGLE_API_ENABLE_RUNTIME_BOUND_TOKEN // "") | ascii_downcase) == "false" | if . then 1 else 0 end' <<<"$V3H_ENV_JSON")"
ENV_READ="$(jq -r 'length' <<<"$V3H_ENV_JSON")"
WANT_OPT=0; [[ "$STAGE" == optout ]] && WANT_OPT=1
if [[ "$ENV_READ" != 0 && "$OPTED" != "$WANT_OPT" ]]; then
  guard_abort "stage $STAGE needs opt-out=$WANT_OPT on agent v3a (agent_v3_token_binding_opt_out), found $OPTED"
fi
[[ "$ENV_READ" != 0 ]] || note "engine env could not be read; relying on the Terraform variable being set as the stage requires"
REPLAY_URL="${V3H_REPLAY_URL:-$(jq -r '.LZV_REPLAY_URL // empty' <<<"$V3H_ENV_JSON")}"
[[ "$REPLAY_URL" == https://* ]] || guard_abort "no replay service URL (agent_v3_replay_url on the agent, or export V3H_REPLAY_URL)"
[[ "$REPLAY_URL" != *"$RT"* ]] || note "WARNING: the replay URL contains the runtime project id; it must be a different project"
note "agent v3a: $AID_A; replay service: $REPLAY_URL"
[[ "$STAGE" == bound ]] || [[ "$(read_stage bound)" != MISSING ]] || guard_abort "run stage bound first (same RUN_ID)"

# The replay comes from outside the perimeter (seed). If the runtime project is in the ENFORCED
# perimeter, VPC-SC refuses the replay before token binding is checked, so the result would not
# isolate binding. Require the runtime project out of perimeter status (dry-run is fine).
RT_NUM="$(project_number runtime)"
run_capture gcloud access-context-manager policies list --organization="$(org_id)" --format=json
POL="$(v3h_json_last | jq -r --arg f "folders/$(folder_id root)" '[.[] | select((.scopes // []) | index($f))][0].name // empty' | sed 's#^accessPolicies/##')"
[[ -n "$POL" ]] || guard_abort "no access policy scoped to the test folder"
run_capture gcloud access-context-manager perimeters describe lzv_ai --policy="$POL" --format=json
IN_STATUS="$(v3h_json_last | jq -r --arg p "projects/$RT_NUM" '[(.status.resources // [])[] | select(. == $p)] | length')"
[[ "$IN_STATUS" == 0 ]] || guard_abort "runtime project is in the ENFORCED perimeter; put the perimeter in dry-run for T48 (v4-deploy.sh dryrun)"

EMPTY_JSON="{}"
MODEL="$(jq -r '.LZV_MODEL // "gemini-3.5-flash"' <<<"$V3H_ENV_JSON")"
LOC="$(jq -r '.LZV_MODEL_LOCATION // "global"' <<<"$V3H_ENV_JSON")"

# Control 2: replay service with the operator's own credentials (token built inside the quoted command, never logged)
export LZV_REPLAY_URL="$REPLAY_URL" LZV_PROJECT="$RT" LZV_MODEL_NAME="$MODEL" LZV_LOC="$LOC"
run_capture_sh 'jq -cn --arg t "$(gcloud auth print-access-token)" --arg p "$LZV_PROJECT" --arg m "$LZV_MODEL_NAME" --arg l "$LZV_LOC" "{token:\$t,project:\$p,model:\$m,location:\$l}" | curl -sS --max-time 90 -H "Authorization: Bearer $(gcloud auth print-identity-token)" -H "Content-Type: application/json" -X POST "$LZV_REPLAY_URL/replay" -d @- -w "\nHTTP %{http_code}\n"'
CTL_JSON="$(grep -E '^\{' "$LZV_LAST_OUT" | head -1)"
CTL_STATUS="$(jq -r '(.status // "none") | tostring' <<<"${CTL_JSON:-$EMPTY_JSON}" 2>/dev/null || echo none)"
CTL_HTTP="$(sed -n 's/^HTTP //p' "$LZV_LAST_OUT" | tail -1)"
note "control 2 (replay service, operator token): replay HTTP=${CTL_HTTP:-none} vertex status=$CTL_STATUS token_sha12=$(jq -r '.token_sha12 // "none"' <<<"${CTL_JSON:-$EMPTY_JSON}" 2>/dev/null)"

# The replay: agent -> replay service, token in memory
v3h_query "$AID_A" "ACTION=replay MODE=guarded"
OWN="$(jq -r '(.own_call_status // "none") | tostring' <<<"${Q_LINE:-$EMPTY_JSON}")"
RS="$(jq -r '(.replay.status // "none") | tostring' <<<"${Q_LINE:-$EMPTY_JSON}")"
RH="$(jq -r '(.replay_http_status // "none") | tostring' <<<"${Q_LINE:-$EMPTY_JSON}")"
SHA12="$(jq -r '.token_sha12 // "none"' <<<"${Q_LINE:-$EMPTY_JSON}")"
EXPIRY="$(jq -r '.token_expiry // "none"' <<<"${Q_LINE:-$EMPTY_JSON}")"
RERR="$(jq -r '((.replay.error_status // "") + " " + (.replay.error_message // "")) | .[0:300]' <<<"${Q_LINE:-$EMPTY_JSON}")"
note "agent replay: own call status=$OWN; replay service HTTP=$RH; replayed status=$RS; token sha12=$SHA12 expiry=$EXPIRY; replay error: ${RERR:- none}"

V=INCONCLUSIVE; W=""
if [[ "$Q_HAVE" != 1 ]]; then W="no result line from the agent (http_rc=$Q_RC)"
elif [[ "$OWN" == 403 || "$RS" == 403 || "$CTL_STATUS" == 403 ]]; then W="403 seen (own=$OWN replay=$RS control=$CTL_STATUS): fixture IAM error, not a binding result"
elif [[ "$OWN" != 200 ]]; then W="control 1 failed: the agent's own call status is $OWN, so the replayed result cannot be attributed to binding"
elif [[ "$CTL_STATUS" != 200 ]]; then W="control 2 failed: replay service with operator credentials gave status $CTL_STATUS (HTTP ${CTL_HTTP:-none})"
elif [[ "$RH" != 200 ]]; then W="replay service itself answered HTTP $RH to the agent (invoker or network problem)"
elif [[ "$STAGE" == bound ]]; then
  case "$RS" in
    401) V=PASS ;;
    200) V=FAIL; W="bound token accepted from the second workload (200): binding not enforced on this Vertex AI call (finding)" ;;
    *)   W="bound replay returned status $RS" ;;
  esac
else
  case "$RS" in
    200) V=PASS ;;
    401) V=FAIL; W="opt-out token refused from the second workload (401)" ;;
    *)   W="opt-out replay returned status $RS" ;;
  esac
fi
write_stage "$V" "$STAGE: own=$OWN control2=$CTL_STATUS replay=$RS sha12=$SHA12${W:+; $W}"

if [[ "$STAGE" == optout ]]; then
  SB="$(read_stage bound)"
  FINAL="$(verdict_merge "$SB" "$V")"
  WHY=""
  [[ "$SB" == PASS ]] || WHY+="stage bound: $SB ($(jq -r '.note // empty' "$LZV_DIR/stages/bound.json" 2>/dev/null)); "
  [[ "$V" == PASS ]] || WHY+="stage optout: $W; "
  [[ "$FINAL" == PASS ]] && WHY=""
  write_result "$FINAL" Enforced "bound: $(jq -r '.note' "$LZV_DIR/stages/bound.json"); optout: own=$OWN control2=$CTL_STATUS replay=$RS sha12=$SHA12" "$WHY"
fi
