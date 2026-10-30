#!/usr/bin/env bash
# T14R: re-test of T14's deploy-order claim (Phase 6 issue H1, human approved 2026-10-25).
# Agent A is deployed while the runtime project is in NO perimeter (not even the dry-run spec),
# then the project joins the enforced perimeter and the SAME agent is queried again.
# Stages: pre | post. The result is written by `post`.
# shellcheck disable=SC2016
set -u
source "$(dirname "$0")/lib.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in pre|post) ;; *) lzv_die "usage: T14R.sh pre|post" ;; esac

LZV_SCOPE="folders/$(folder_id root)"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/vertex-ai/docs/general/vpc-service-controls"
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/private-service-connect-interface"
)
header T14R "Reach" "Agent deployed before the project joins a perimeter" \
  "pre: tool status 200; post (same agent, project now in the enforced perimeter): tool status 200 (docs: an agent deployed before the project joins a perimeter keeps internet access; article trap #7)" \
  "$STAGE"
note "no resources are created by this script (agent A is Terraform-managed); no cleanup_trap registered"
note "PASS means the documented gap was reproduced (egress still allowed), not that a control blocked something"

RT_NUM="$(project_number runtime)"
json_last() { sed -n '/^[[{]/,$p' "$LZV_LAST_OUT"; }

# --- Perimeter guard: is the runtime project in the dry-run spec / enforced status? ---
# perimeter_state -> sets IN_SPEC, IN_STATUS (0/1), NING (status ingress count)
perimeter_state() {
  local pol
  run_capture gcloud access-context-manager policies list --organization="$(org_id)" --format=json
  pol="$(json_last | jq -r --arg f "$LZV_SCOPE" '[.[] | select((.scopes // []) | index($f))][0].name // empty' | sed 's#^accessPolicies/##')"
  [[ -n "$pol" ]] || guard_abort "no access policy scoped to $LZV_SCOPE"
  run_capture gcloud access-context-manager perimeters describe lzv_ai --policy="$pol" --format=json
  IN_SPEC="$(json_last | jq -r --arg p "projects/$RT_NUM" '[(.spec.resources // [])[] | select(. == $p)] | length')"
  IN_STATUS="$(json_last | jq -r --arg p "projects/$RT_NUM" '[(.status.resources // [])[] | select(. == $p)] | length')"
  NING="$(json_last | jq -r '(.status.ingressPolicies // []) | length')"
  [[ "$IN_SPEC" =~ ^[01]$ && "$IN_STATUS" =~ ^[01]$ && "$NING" =~ ^[0-9]+$ ]] || guard_abort "cannot read perimeter state"
  note "perimeter lzv_ai: runtime in spec=$IN_SPEC, in status=$IN_STATUS, status ingressPolicies=$NING"
}

# --- Query the agent and classify the tool result (same method as T14) ---
query_agent() {
  local id="$1" region cmd frs
  region="${id#*/locations/}"; region="${region%%/*}"
  cmd='out="$(printf "Authorization: Bearer %s\n" "$(gcloud auth print-access-token)" | curl -sS -N --max-time 180 -H @- -H "Content-Type: application/json" -X POST "https://'"$region"'-aiplatform.googleapis.com/v1/'"$id"':streamQuery?alt=sse" -d '"'"'{"class_method":"async_stream_query","input":{"user_id":"lzv-t14r","message":"Fetch https://example.com"}}'"'"' -w "\nHTTP %{http_code}\n" 2>&1)"; printf "%s\n" "$out"; case "$out" in *$'"'"'\n'"'"'HTTP\ 200) exit 0 ;; esac; exit 1'
  run_capture_sh "$cmd"
  QRC="$LZV_LAST_RC"
  frs="$(sed 's/^data: *//' "$LZV_LAST_OUT" | jq -cR 'fromjson? | .. | objects | (.function_response // .functionResponse // empty)
    | (.response // {}) as $r | (if ($r|type)=="object" then $r else {} end) as $o
    | {s: (($o.status // $o.status_code // $o.statusCode // "") | tostring), e: (($o.error // $o.exception // "") | tostring)}' 2>/dev/null)"
  FR_N="$(printf '%s' "$frs" | grep -c .)"
  FR_STATUS=""; FR_ERR=""
  if grep -q '"s":"200"' <<<"$frs"; then
    FR_STATUS=200
  else
    FR_ERR="$(jq -r 'select(.e != "" or .s != "") | "status=\(.s) error=\(.e)"' <<<"$frs" 2>/dev/null | head -1 | cut -c1-200)"
  fi
  note "http_rc=$QRC function_responses=$FR_N status=${FR_STATUS:-none} err=${FR_ERR:-none}"
}

classify() {  # sets V, OBS, WHY for one query; $1 = what a 200 means for this stage
  if [[ "$FR_STATUS" == 200 ]]; then
    V=PASS; OBS="tool status 200"; WHY=""
  elif [[ -n "$FR_ERR" ]]; then
    V=FAIL; OBS="tool result $FR_ERR"; WHY="$1"
  elif [[ "$QRC" -ne 0 ]]; then
    V=INCONCLUSIVE; OBS="query failed"; WHY="query to agent A failed (not HTTP 200 or curl error); no tool result"
  else
    V=INCONCLUSIVE; OBS="no function response"; WHY="query succeeded but no function response appeared (LLM may not have called the tool)"
  fi
}

AID="$(agents_tf '.agent_a.value.id' 2>/dev/null)" || AID=""
[[ -n "$AID" ]] || guard_abort "deploy agent A first"
note "agent A: $AID"
run_capture gcloud asset search-all-resources --scope="projects/$RT_NUM" --asset-types=aiplatform.googleapis.com/ReasoningEngine --format='json(name,createTime)' --billing-project="$(project_id runtime)"

perimeter_state
case "$STAGE" in
pre)
  [[ "$IN_SPEC" == 0 && "$IN_STATUS" == 0 ]] || guard_abort "stage pre needs the runtime project outside the perimeter (spec and status)"
  query_agent "$AID"
  classify "baseline: agent A could not fetch the URL before the project joined any perimeter"
  [[ "$V" == FAIL ]] && V=INCONCLUSIVE   # a failed baseline cannot test the claim
  write_stage "$V" "pre: $OBS${WHY:+; $WHY}"
  ;;
post)
  [[ "$IN_STATUS" == 1 && "$NING" -gt 0 ]] || guard_abort "stage post needs the runtime project in the enforced perimeter with the operator ingress rule"
  query_agent "$AID"
  classify "finding: agent A (deployed before the project joined) lost internet access after enforcement; docs claim not reproduced"
  write_stage "$V" "post: $OBS${WHY:+; $WHY}"
  sp="$(read_stage pre)"; reasons=""
  if [[ "$sp" == MISSING ]]; then sp=INCONCLUSIVE; reasons+="stage pre missing; "; fi
  [[ "$sp" == PASS ]] || reasons+="stage pre: $sp ($(jq -r '.note // empty' "$LZV_DIR/stages/pre.json" 2>/dev/null)); "
  [[ "$V" == PASS ]] || reasons+="stage post: $WHY; "
  final="$(verdict_merge "$sp" "$V")"
  [[ "$sp" == PASS ]] || final=INCONCLUSIVE   # without a working baseline the claim is not tested
  pnote="$(jq -r '.note // "not run"' "$LZV_DIR/stages/pre.json" 2>/dev/null || echo "not run")"
  write_result "$final" Enforced "${pnote}; post: $OBS" "$reasons"
  ;;
esac
