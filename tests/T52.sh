#!/usr/bin/env bash
# T52 (v3 B13): lateral access through the default roles. Plan: plans/v3-harness-boundary-tests.md section 3b
# (pre-registered 2026-11-12, before this script). Agent A = v3a, agent B = the sibling lzv-v3-x. The operator creates one
# session on A (synthetic state). B, ACTION=sessions: sessions.list and sessions.get on A, memories.list on A,
# reasoningEngines.query (get_session) on A.
#   default  no extra grant (T40 run 2: the first deploy adds agentDefaultAccess only, not agentContextEditor)
#   granted  infra/ v3h_t52_grant_context_editor=true applied >= 7 min earlier (V3H_WAITED_7MIN=yes; human-approved);
#            writes the result. The orchestrator removes the grant afterwards.
# Controls: the operator's same calls return 200.
# Expected: default: all four 403. granted: sessions list/get and memories list 200 (allowed action, no per-agent
# scoping documented), query 403. Falsified if: default allows any call, or granted refuses the session/memory reads.
# shellcheck disable=SC2016
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib-v3h.sh
source "$(dirname "$0")/lib-v3h.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in default|granted) ;; *) lzv_die "usage: T52.sh default|granted" ;; esac

RT="$(project_id runtime)"
LZV_SCOPE="projects/$RT"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/agent-identity"
  "https://docs.cloud.google.com/vertex-ai/docs/general/access-control"
)
header T52 "B13 (Enforced)" "Agent B reads/queries agent A's sessions and memory, without and with project-level agentContextEditor on the agents principal set; control: the operator's same calls 200" \
  "default (no extra grant): sessions.list, sessions.get, memories.list and reasoningEngines.query on A from B all 403. granted (agentContextEditor on the project): B can list and read A's sessions and memories (200, recorded as an allowed action: no per-agent scoping documented); reasoningEngines.query on A still 403. Falsified if: default allows any call, or granted refuses the session/memory reads (then a per-agent scope exists; record how). Tier: Enforced. 2+ runs. Synthetic session content only." \
  "$STAGE"
note "plan claim B13; the operator creates one session with synthetic state; the grant is Terraform-managed (infra/v3h-t52.tf); no cleanup_trap registered"

AID_A="$(agents_tf '.agent_v3.value.a.id' 2>/dev/null)" || AID_A=""
AID_B="$(agents_tf '.agent_v3.value.x.id' 2>/dev/null)" || AID_B=""
[[ -n "$AID_A" && "$AID_A" != null && -n "$AID_B" && "$AID_B" != null ]] || guard_abort "T52 needs v3a (A) and lzv-v3-x (B)"
GRANT="$(gcloud projects get-iam-policy "$RT" --format=json 2>/dev/null | jq -r '[.bindings[] | select(.role == "roles/aiplatform.agentContextEditor") | .members[] | select(test("principalSet://agents"))] | length')"
note "agentContextEditor bindings for the agents principal set in the runtime project: $GRANT"
case "$STAGE" in
  default) [[ "$GRANT" == 0 ]] || guard_abort "stage default needs no agentContextEditor grant for the agents principal set" ;;
  granted) [[ "$GRANT" -ge 1 ]] || guard_abort "stage granted needs infra/ v3h_t52_grant_context_editor=true applied"
           [[ "${V3H_WAITED_7MIN:-}" == yes ]] || guard_abort "stage granted runs >= 7 min after the grant (V3H_WAITED_7MIN=yes)" ;;
esac

REGION="${AID_A#*/locations/}"; REGION="${REGION%%/*}"
BASE="https://${REGION}-aiplatform.googleapis.com/v1/${AID_A}"
op() {  # op METHOD URL [JSON] -> OP_CODE (operator credentials)
  export LZV_M="$1" LZV_URL="$2" LZV_J="${3:-}"
  run_capture_sh 'if [ -n "$LZV_J" ]; then d=(-d "$LZV_J"); else d=(); fi; curl -sS --max-time 60 -X "$LZV_M" -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "Content-Type: application/json" "$LZV_URL" "${d[@]}" -w "\nHTTP %{http_code}\n"'
  OP_CODE="$(sed -n 's/^HTTP //p' "$LZV_LAST_OUT" | tail -1)"
}
op POST "$BASE:query" '{"class_method":"async_create_session","input":{"user_id":"lzv-t52","state":{"note":"synthetic t52 session"}}}'
SID="$(sed -n '/^{/,$p' "$LZV_LAST_OUT" | sed '/^HTTP /d' | jq -r '.output.id // empty' 2>/dev/null)"
[[ "$OP_CODE" == 200 && "$SID" =~ ^[0-9]+$ ]] || guard_abort "operator could not create a session on A (HTTP $OP_CODE)"
op GET "$BASE/sessions?pageSize=5"; C1="$OP_CODE"
op GET "$BASE/sessions/$SID"; C2="$OP_CODE"
op GET "$BASE/memories?pageSize=5"; C3="$OP_CODE"
op POST "$BASE:query" "{\"class_method\":\"get_session\",\"input\":{\"user_id\":\"lzv-t52\",\"session_id\":\"$SID\"}}"; C4="$OP_CODE"
note "operator session $SID on A; controls: sessions.list=$C1 sessions.get=$C2 memories.list=$C3 query=$C4"

EMPTY_JSON="{}"
v3h_query "$AID_B" "ACTION=sessions ENGINE=$AID_A SESSION=$SID USER=lzv-t52"
P="$(jq -c '.probe.calls // {}' <<<"${Q_LINE:-$EMPTY_JSON}")"
g() { jq -r --arg k "$1" '(.[$k].status // "none") | tostring' <<<"$P"; }
B1="$(g sessions_list)"; B2="$(g sessions_get)"; B3="$(g memories_list)"; B4="$(g query_get_session)"
note "B on A: sessions.list=$B1 sessions.get=$B2 memories.list=$B3 query(get_session)=$B4 (mtls=$(jq -r '.probe.mtls // "?"' <<<"${Q_LINE:-$EMPTY_JSON}"))"

V=INCONCLUSIVE; W=""
if [[ "$Q_HAVE" != 1 ]]; then W="no result line from agent B"
elif [[ "$C1" != 200 || "$C2" != 200 || "$C3" != 200 || "$C4" != 200 ]]; then W="control failed (operator $C1/$C2/$C3/$C4)"
elif [[ "$STAGE" == default ]]; then
  if [[ "$B1" == 403 && "$B2" == 403 && "$B3" == 403 && "$B4" == 403 ]]; then V=PASS
  elif [[ "$B1" == 200 || "$B2" == 200 || "$B3" == 200 || "$B4" == 200 ]]; then V=FAIL; W="B reached A's sessions/memory/query without any extra grant"
  else W="unexpected statuses ($B1/$B2/$B3/$B4)"; fi
else
  if [[ "$B1" == 200 && "$B2" == 200 && "$B3" == 200 && "$B4" == 403 ]]; then V=PASS
  elif [[ "$B1" == 403 || "$B2" == 403 || "$B3" == 403 ]]; then V=FAIL; W="B refused on A's sessions/memory with agentContextEditor granted: a per-agent scope exists (record how)"
  elif [[ "$B4" == 200 ]]; then V=FAIL; W="B could query A (reasoningEngines.query) with agentContextEditor"
  else W="unexpected statuses ($B1/$B2/$B3/$B4)"; fi
fi
write_stage "$V" "$STAGE: B on A list=$B1 get=$B2 memories=$B3 query=$B4; controls $C1/$C2/$C3/$C4${W:+; $W}"
if [[ "$STAGE" == granted ]]; then
  SD="$(read_stage default)"; SD="${SD/MISSING/INCONCLUSIVE}"
  FINAL="$(verdict_merge "$SD" "$V")"
  WHY=""
  [[ "$SD" == PASS ]] || WHY+="default: $SD ($(jq -r '.note // empty' "$LZV_DIR/stages/default.json" 2>/dev/null)); "
  [[ "$V" == PASS ]] || WHY+="granted: $W; "
  [[ "$FINAL" == PASS ]] && WHY=""
  write_result "$FINAL" Enforced "default: $(jq -r '.note // empty' "$LZV_DIR/stages/default.json" 2>/dev/null); granted: list=$B1 get=$B2 memories=$B3 query=$B4 (allowed action recorded)" "$WHY"
fi
