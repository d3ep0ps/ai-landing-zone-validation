#!/usr/bin/env bash
# T14: managed runtime egress, agent A (deployed before perimeter enforcement) vs agent B (after). Stages: a | b
# shellcheck disable=SC2016
set -u
source "$(dirname "$0")/lib.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in a|b) ;; *) lzv_die "usage: T14.sh a|b" ;; esac

LZV_SCOPE="folders/$(folder_id root)"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/vertex-ai/docs/general/vpc-service-controls"
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/use-an-adk-agent"
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/private-service-connect-interface"
)
header T14 "Reach" "Managed runtime egress" \
  "A succeeds; B fails (proves article trap #7). No VPC-SC log entry required for B's egress failure" \
  "$STAGE"

LIMIT="Known limitation (RUN-ORDER.md): agent A is deployed while the runtime project is in the perimeter dry-run spec; we assume dry-run membership does not count as 'in a perimeter before deploy'."
VPCSC_RE='Request violates VPC Service Controls|vpcServiceControlsUniqueIdentifier'
note "no resources are created by this script (agents are Terraform-managed); no cleanup_trap registered"

json_last() { sed -n '/^[[{]/,$p' "$LZV_LAST_OUT"; }

# --- Perimeter state guard (copied from T13) ---------------------------------
# $1 = want: dryrun-only | enforced-noingress | enforced-ingress
perimeter_guard() {
  local want="$1" pol nres ning
  run_capture gcloud access-context-manager policies list --organization="$(org_id)" --format=json
  pol="$(json_last | jq -r --arg f "$LZV_SCOPE" '[.[] | select((.scopes // []) | index($f))][0].name // empty' | sed 's#^accessPolicies/##')"
  [[ -n "$pol" ]] || guard_abort "no access policy scoped to $LZV_SCOPE"
  run_capture gcloud access-context-manager perimeters describe lzv_ai --policy="$pol" --format=json
  nres="$(json_last | jq -r '(.status.resources // []) | length')"
  ning="$(json_last | jq -r '(.status.ingressPolicies // []) | length')"
  [[ "$nres" =~ ^[0-9]+$ && "$ning" =~ ^[0-9]+$ ]] || guard_abort "cannot read perimeter state"
  note "perimeter lzv_ai: status resources=$nres, status ingressPolicies=$ning (want $want)"
  case "$want" in
    dryrun-only)        [[ "$nres" -eq 0 ]] || guard_abort "perimeter is enforced (status resources present); stage $STAGE needs dry-run only" ;;
    enforced-ingress)   [[ "$nres" -gt 0 && "$ning" -gt 0 ]] || guard_abort "stage $STAGE needs an enforced perimeter with an ingress policy" ;;
  esac
}

# --- Query the agent and classify the tool result ----------------------------
# query_agent ID ; sets QRC (0 only on HTTP 200), FR_N, FR_STATUS, FR_ERR, DESC
query_agent() {
  local id="$1" region cmd
  region="${id#*/locations/}"; region="${region%%/*}"
  cmd='out="$(printf "Authorization: Bearer %s\n" "$(gcloud auth print-access-token)" | curl -sS -N --max-time 180 -H @- -H "Content-Type: application/json" -X POST "https://'"$region"'-aiplatform.googleapis.com/v1/'"$id"':streamQuery?alt=sse" -d '"'"'{"class_method":"async_stream_query","input":{"user_id":"lzv-t14","message":"Fetch https://example.com"}}'"'"' -w "\nHTTP %{http_code}\n" 2>&1)"; printf "%s\n" "$out"; case "$out" in *$'"'"'\n'"'"'HTTP\ 200) exit 0 ;; esac; exit 1'
  run_capture_sh "$cmd"
  QRC="$LZV_LAST_RC"
  local frs
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
  DESC="http_rc=$QRC function_responses=$FR_N status=${FR_STATUS:-none} err=${FR_ERR:-none}"
  note "$DESC"
}

query_agent_for() {  # query_agent_for KEY -> ID or guard_abort
  agents_tf ".$1.value.id" 2>/dev/null
}

case "$STAGE" in
a)
  perimeter_guard dryrun-only
  AID="$(query_agent_for agent_a)" || AID=""
  [[ -n "$AID" ]] || guard_abort "deploy agent A first"
  query_agent "$AID"
  if [[ "$FR_STATUS" == 200 ]]; then
    v=PASS; why=""; obs="function response status 200"
  elif [[ -n "$FR_ERR" ]]; then
    v=FAIL; why="agent A tool call did not return 200 ($FR_ERR); $LIMIT"; obs="tool result $FR_ERR"
  elif [[ "$QRC" -ne 0 ]]; then
    v=INCONCLUSIVE; why="query to agent A failed (not HTTP 200 or curl error); no tool result"; obs="query failed"
  else
    v=INCONCLUSIVE; why="query succeeded but no function response with status/error appeared (LLM may not have called the tool)"; obs="no function response"
  fi
  write_stage "$v" "A: $obs${why:+; $why}"
  ;;
b)
  perimeter_guard enforced-ingress
  AID="$(query_agent_for agent_b)" || AID=""
  [[ -n "$AID" ]] || guard_abort "deploy agent B first"
  query_agent "$AID"
  if [[ "$FR_STATUS" == 200 ]]; then
    v=FAIL; why="agent B fetched the URL with status 200 despite the perimeter"; obs="function response status 200"
  elif [[ -n "$FR_ERR" ]]; then
    v=PASS; why=""; obs="tool result $FR_ERR"
  elif [[ "$QRC" -ne 0 ]] && last_output_matches "$VPCSC_RE"; then
    v=INCONCLUSIVE; why="query refused with a VPC-SC error (operator ingress rule missing or wrong)"; obs="query refused by VPC-SC"
  elif [[ "$QRC" -ne 0 ]]; then
    v=INCONCLUSIVE; why="query to agent B failed (not HTTP 200 or curl error); no tool result"; obs="query failed"
  else
    v=INCONCLUSIVE; why="query succeeded but no function response with status/error appeared (LLM may not have called the tool)"; obs="no function response"
  fi
  write_stage "$v" "B: $obs${why:+; $why}"
  sa="$(read_stage a)"
  reasons=""
  if [[ "$sa" == MISSING ]]; then sa=INCONCLUSIVE; reasons+="stage a missing; "; fi
  [[ "$sa" == PASS ]] || reasons+="stage a: $sa ($(jq -r '.note // empty' "$LZV_DIR/stages/a.json" 2>/dev/null)); "
  [[ "$v" == PASS ]] || reasons+="stage b: $why; "
  final="$(verdict_merge "$sa" "$v")"
  [[ "$final" == PASS ]] || reasons+="$LIMIT"
  anote="$(jq -r '.note // "not run"' "$LZV_DIR/stages/a.json" 2>/dev/null || echo "not run")"
  write_result "$final" Enforced "A: ${anote#A: }; B: $obs" "$reasons"
  ;;
esac
