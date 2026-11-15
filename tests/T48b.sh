#!/usr/bin/env bash
# T48b (v3 B9): wrong certificate vs no certificate. Plan: plans/v3-harness-boundary-tests.md section 3b (pre-registered
# 2026-11-12, before this script). Two bound engines from the T48 tarball: v3a (X) and the sibling lzv-v3-x (Y).
# X: ACTION=relay_put NONCE=n (own mTLS call, then its token -> replay service single-use relay, memory only).
# Y: ACTION=relay_take NONCE=n (takes X's token, presents it over Y's OWN mTLS session to the mTLS Vertex endpoint;
#    control: Y's own token over the same kind of session). Tokens never reach this script (only SHA-256 prefixes).
# Docs are silent on a fingerprint match (doc check NOT FOUND): the expected 401 is an inference.
# Falsified if: X's token over Y's session returns 200.
# shellcheck disable=SC2016
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib-v3h.sh
source "$(dirname "$0")/lib-v3h.sh"
require_config

RT="$(project_id runtime)"; RT_NUM="$(project_number runtime)"
LZV_SCOPE="projects/$RT"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/access-context-manager/docs/caa-agent-security"
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/agent-identity"
)
header T48b "B9 (Enforced)" "Agent X's bound token presented over agent Y's own mTLS session (Y's agent certificate) to the mTLS Vertex AI endpoint; controls: X's own call 200, Y's own token over its session 200" \
  "Expected: 401 (UNAUTHENTICATED / Context-Aware Access). Falsified if: 200 (binding not checked against the presenting certificate). INCONCLUSIVE if: a control fails or any 403. Docs are silent on a fingerprint match; the expectation is an inference from 'only usable by the agent running in its provisioned environment'. Tier: Enforced. 2+ runs. Tokens in memory only." \
  ""
note "plan claim B9 (wrong certificate); no resources are created by this script; no cleanup_trap registered"
note "T48b v2 (2026-11-13, plan 3b deviations): X's token goes through a session that does not refresh on 401, so the server answer is recorded; expected result unchanged"

AID_X="$(agents_tf '.agent_v3.value.a.id' 2>/dev/null)" || AID_X=""
AID_Y="$(agents_tf '.agent_v3.value.x.id' 2>/dev/null)" || AID_Y=""
[[ -n "$AID_X" && "$AID_X" != null && -n "$AID_Y" && "$AID_Y" != null ]] || guard_abort "deploy v3a and the sibling lzv-v3-x (agent_v3_set a, x)"
for id in "$AID_X" "$AID_Y"; do
  v3h_engine_env "$id"
  [[ "$(jq -r '((.GOOGLE_API_ENABLE_RUNTIME_BOUND_TOKEN // "") | ascii_downcase) == "false"' <<<"$V3H_ENV_JSON")" == false ]] \
    || guard_abort "$id has the token-binding opt-out; T48b needs two bound engines"
done
run_capture gcloud access-context-manager policies list --organization="$(org_id)" --format=json
POL="$(v3h_json_last | jq -r --arg f "folders/$(folder_id root)" '[.[] | select((.scopes // []) | index($f))][0].name // empty' | sed 's#^accessPolicies/##')"
run_capture gcloud access-context-manager perimeters describe lzv_ai --policy="$POL" --format=json
[[ "$(v3h_json_last | jq -r --arg p "projects/$RT_NUM" '[(.status.resources // [])[] | select(. == $p)] | length')" == 0 ]] \
  || guard_abort "runtime project is in the ENFORCED perimeter; T48b needs dry-run (the relay is outside the perimeter)"

NONCE="t48b$(date -u +%H%M%S)$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
note "X: $AID_X; Y: $AID_Y; nonce $NONCE"
EMPTY_JSON="{}"
v3h_query "$AID_X" "ACTION=relay_put NONCE=$NONCE"
PX="$(jq -c '.probe // {}' <<<"${Q_LINE:-$EMPTY_JSON}")"
X_OWN="$(jq -r '(.own.status // "none") | tostring' <<<"$PX")"; X_MTLS="$(jq -r '(.own_mtls // "none") | tostring' <<<"$PX")"
PUT="$(jq -r '(.put_status // "none") | tostring' <<<"$PX")"; X_SHA="$(jq -r '.token_sha12 // "none"' <<<"$PX")"
note "X: own call over its mTLS session=$X_OWN (is_mtls=$X_MTLS); relay put=$PUT; token sha12=$X_SHA"
v3h_query "$AID_Y" "ACTION=relay_take NONCE=$NONCE"
PY="$(jq -c '.probe // {}' <<<"${Q_LINE:-$EMPTY_JSON}")"
TAKE="$(jq -r '(.take_status // "none") | tostring' <<<"$PY")"; T_SHA="$(jq -r '.x_token_sha12 // "none"' <<<"$PY")"
XY="$(jq -r '(.x_over_y.status // "none") | tostring' <<<"$PY")"; XY_M="$(jq -r '(.x_over_y_mtls // "none") | tostring' <<<"$PY")"
XY_E="$(jq -r '((.x_over_y.error_status // "") + " " + (.x_over_y.error // "")) | .[0:200]' <<<"$PY")"
YO="$(jq -r '(.y_own.status // "none") | tostring' <<<"$PY")"; YO_M="$(jq -r '(.y_own_mtls // "none") | tostring' <<<"$PY")"
note "Y: relay take=$TAKE (sha12 $T_SHA, same token=$([[ "$T_SHA" == "$X_SHA" ]] && echo yes || echo no)); X's token over Y's session=$XY (is_mtls=$XY_M; $XY_E); Y own token=$YO (is_mtls=$YO_M)"

V=INCONCLUSIVE; W=""
if [[ "$X_OWN" == 403 || "$XY" == 403 || "$YO" == 403 ]]; then W="403 seen (fixture IAM), not a binding result"
elif [[ "$X_OWN" != 200 ]]; then W="control failed: X's own call $X_OWN"
elif [[ "$YO" != 200 ]]; then W="control failed: Y's own token over its session $YO"
elif [[ "$T_SHA" != "$X_SHA" || "$TAKE" != 200 ]]; then W="relay did not deliver X's token (take=$TAKE)"
elif [[ "$XY_M" != true ]]; then W="Y's session with X's token was not mTLS (is_mtls=$XY_M): no certificate presented, not the wrong one"
else
  case "$XY" in
    401) V=PASS ;;
    200) V=FAIL; W="X's bound token accepted over Y's mTLS session (200): binding not checked against the presenting certificate (finding)" ;;
    *)   W="X's token over Y's session returned $XY" ;;
  esac
fi
write_result "$V" Enforced "X own=$X_OWN; X token over Y session=$XY ($XY_E); Y own=$YO; token sha12 $X_SHA" "$W"
