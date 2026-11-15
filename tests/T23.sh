#!/usr/bin/env bash
# T23: DC2 (3), article trap #7 (T14R v2). Agent A is deployed while the runtime project is in NO
# perimeter; the project then joins the enforced perimeter with an ingress rule for the principal://
# identities of A and B (exact strings reported by the platform); agent B is deployed AFTER
# enforcement. Both fetch https://example.com.
# Stages: pre | post. The result is written by `post`.
# Order (see tests/RUN-ORDER-v11-c.md): pre -> enforce with ingress [A] -> deploy B -> read B's
# identity -> apply ingress [A, B] (vpc_sc_agent_ingress_identities) -> wait 15 min -> post.
# shellcheck disable=SC2016
set -u
source "$(dirname "$0")/lib.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in pre|post) ;; *) lzv_die "usage: T23.sh pre|post" ;; esac

LZV_SCOPE="folders/$(folder_id root)"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/vpc-service-controls/docs/supported-identities"
  "https://docs.cloud.google.com/vpc-service-controls/docs/ingress-egress-rules"
  "https://docs.cloud.google.com/vertex-ai/docs/general/vpc-service-controls"
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/agent-identity"
)
header T23 "Reach" "DC2 (3): agent deployed before the project joins the perimeter, ingress rule for agent identities" \
  "Per Google docs: A's fetch succeeds, B's fetch fails. That A's API calls work with the ingress rule is a prediction (undocumented); if they are still refused: INCONCLUSIVE with the violation reason" \
  "$STAGE"
note "no resources are created by this script (agents are Terraform-managed); no cleanup_trap registered"
note "PASS means A kept internet access and B (deployed after enforcement) lost it, with the same ingress rule for both"

RT_NUM="$(project_number runtime)"
RT_ID="$(project_id runtime)"
VPCSC_RE='Request violates VPC Service Controls|vpcServiceControlsUniqueIdentifier|NO_MATCHING_ACCESS_LEVEL'
json_last() { sed -n '/^[[{]/,$p' "$LZV_LAST_OUT"; }

# perimeter_state -> IN_SPEC, IN_STATUS (0/1), NING; PERIM_JSON_FILE holds the describe output
perimeter_state() {
  local pol
  run_capture gcloud access-context-manager policies list --organization="$(org_id)" --format=json
  pol="$(json_last | jq -r --arg f "$LZV_SCOPE" '[.[] | select((.scopes // []) | index($f))][0].name // empty' | sed 's#^accessPolicies/##')"
  [[ -n "$pol" ]] || guard_abort "no access policy scoped to $LZV_SCOPE"
  run_capture gcloud access-context-manager perimeters describe lzv_ai --policy="$pol" --format=json
  PERIM_JSON="$(json_last)"
  IN_SPEC="$(jq -r --arg p "projects/$RT_NUM" '[(.spec.resources // [])[] | select(. == $p)] | length' <<<"$PERIM_JSON")"
  IN_STATUS="$(jq -r --arg p "projects/$RT_NUM" '[(.status.resources // [])[] | select(. == $p)] | length' <<<"$PERIM_JSON")"
  NING="$(jq -r '(.status.ingressPolicies // []) | length' <<<"$PERIM_JSON")"
  [[ "$IN_SPEC" =~ ^[01]$ && "$IN_STATUS" =~ ^[01]$ && "$NING" =~ ^[0-9]+$ ]] || guard_abort "cannot read perimeter state"
  note "perimeter lzv_ai: runtime in spec=$IN_SPEC, in status=$IN_STATUS, status ingressPolicies=$NING"
}

# query_agent LABEL ID -> sets CLS (200|toolerr|refused|queryfail|nofr), OBS
query_agent() {
  local label="$1" id="$2" region cmd frs qrc fr_n fr_status fr_err
  region="${id#*/locations/}"; region="${region%%/*}"
  cmd='out="$(printf "Authorization: Bearer %s\n" "$(gcloud auth print-access-token)" | curl -sS -N --max-time 180 -H @- -H "Content-Type: application/json" -X POST "https://'"$region"'-aiplatform.googleapis.com/v1/'"$id"':streamQuery?alt=sse" -d '"'"'{"class_method":"async_stream_query","input":{"user_id":"lzv-t23","message":"Fetch https://example.com"}}'"'"' -w "\nHTTP %{http_code}\n" 2>&1)"; printf "%s\n" "$out"; case "$out" in *$'"'"'\n'"'"'HTTP\ 200) exit 0 ;; esac; exit 1'
  run_capture_sh "$cmd"
  qrc="$LZV_LAST_RC"
  frs="$(sed 's/^data: *//' "$LZV_LAST_OUT" | jq -cR 'fromjson? | .. | objects | (.function_response // .functionResponse // empty)
    | (.response // {}) as $r | (if ($r|type)=="object" then $r else {} end) as $o
    | {s: (($o.status // $o.status_code // $o.statusCode // "") | tostring), e: (($o.error // $o.exception // "") | tostring)}' 2>/dev/null)"
  fr_n="$(printf '%s' "$frs" | grep -c .)"
  fr_status=""; fr_err=""
  if grep -q '"s":"200"' <<<"$frs"; then
    fr_status=200
  else
    fr_err="$(jq -r 'select(.e != "" or .s != "") | "status=\(.s) error=\(.e)"' <<<"$frs" 2>/dev/null | head -1 | cut -c1-200)"
  fi
  if [[ "$fr_status" == 200 ]]; then CLS=200; OBS="tool status 200"
  elif [[ -n "$fr_err" ]]; then CLS=toolerr; OBS="tool result $fr_err"
  elif [[ "$qrc" -ne 0 ]] && last_output_matches "$VPCSC_RE"; then CLS=refused; OBS="query refused by VPC-SC"
  elif [[ "$qrc" -ne 0 ]]; then CLS=queryfail; OBS="query failed"
  else CLS=nofr; OBS="no function response"; fi
  note "agent $label: http_rc=$qrc function_responses=$fr_n status=${fr_status:-none} err=${fr_err:-none} -> $CLS"
}

# violation_reason -> VIOL: latest VPC-SC audit entries for the runtime project (read-only)
violation_reason() {
  run_capture gcloud logging read 'protoPayload.metadata."@type"="type.googleapis.com/google.cloud.audit.VpcServiceControlAuditMetadata"' \
    --project="$RT_ID" --freshness=30m --limit=10 --format=json
  VIOL="$(json_last | jq -r '[.[] | "\(.protoPayload.metadata.violationReason // "?") caller=\(.protoPayload.authenticationInfo.principalSubject // .protoPayload.authenticationInfo.principalEmail // "?") method=\(.protoPayload.methodName // "?")"] | unique | join("; ")' 2>/dev/null | cut -c1-600)"
  [[ -n "$VIOL" ]] || VIOL="no VPC-SC audit entry found in the last 30 minutes"
  note "VPC-SC audit entries: $VIOL"
}

AID="$(agents_tf '.agent_a.value.id' 2>/dev/null)" || AID=""
[[ -n "$AID" ]] || guard_abort "deploy agent A first"
A_PRINC="$(agents_tf '.agent_a.value.identity' 2>/dev/null)" || A_PRINC=""
B_PRINC="$(agents_tf '.agent_b.value.identity' 2>/dev/null)" || B_PRINC=""
[[ "$A_PRINC" == principal://* ]] || note "agent A identity is not a principal:// string: '${A_PRINC:-empty}'"
echo "AGENT A principal (for vpc_sc_agent_ingress_identities): ${A_PRINC:-unknown}"
echo "AGENT B principal (for vpc_sc_agent_ingress_identities): ${B_PRINC:-not deployed yet}"
note "agent A: $AID; identity: ${A_PRINC:-unknown}"
note "agent B identity: ${B_PRINC:-not deployed yet}"

perimeter_state
case "$STAGE" in
pre)
  [[ "$IN_SPEC" == 0 && "$IN_STATUS" == 0 ]] || guard_abort "stage pre needs the runtime project outside the perimeter (spec and status)"
  [[ -z "$B_PRINC" ]] || guard_abort "stage pre needs agent B not deployed yet (B is deployed after enforcement)"
  query_agent A "$AID"
  case "$CLS" in
    200) V=PASS; WHY="" ;;
    toolerr) V=INCONCLUSIVE; WHY="baseline: agent A could not fetch the URL before the project joined any perimeter" ;;
    *) V=INCONCLUSIVE; WHY="baseline query to agent A gave no tool result ($OBS)" ;;
  esac
  write_stage "$V" "pre: A $OBS${WHY:+; $WHY}"
  ;;
post)
  [[ "$IN_STATUS" == 1 && "$NING" -gt 0 ]] || guard_abort "stage post needs the runtime project in the enforced perimeter with ingress policies"
  BID="$(agents_tf '.agent_b.value.id' 2>/dev/null)" || BID=""
  [[ -n "$BID" && -n "$B_PRINC" && -n "$A_PRINC" ]] || guard_abort "deploy agent B after enforcement first"
  for p in "$A_PRINC" "$B_PRINC"; do
    jq -e --arg p "$p" '[(.status.ingressPolicies // [])[] | (.ingressFrom.identities // [])[] | select(. == $p)] | length > 0' <<<"$PERIM_JSON" >/dev/null \
      || guard_abort "perimeter ingress policies do not contain the identity $p; set vpc_sc_agent_ingress_identities and wait 15 minutes"
  done
  note "ingress rule lists both agent identities"

  query_agent A "$AID"
  CA="$CLS"; OA="$OBS"
  case "$CA" in
    200) VA=PASS; WA="" ;;
    toolerr) VA=FAIL; WA="agent A (deployed before the project joined) lost internet access after enforcement; docs claim not reproduced" ;;
    refused) violation_reason; VA=INCONCLUSIVE; WA="A's own Vertex AI call was refused by VPC-SC even with the ingress rule (prediction not met): $VIOL" ;;
    *) VA=INCONCLUSIVE; WA="query to agent A gave no tool result ($OA)" ;;
  esac
  write_stage "$VA" "post A: $OA${WA:+; $WA}"

  query_agent B "$BID"
  CB="$CLS"; OB="$OBS"
  case "$CB" in
    toolerr) VB=PASS; WB="" ;;
    200) VB=FAIL; WB="agent B (deployed after enforcement) fetched the URL with status 200; docs claim not reproduced" ;;
    refused) violation_reason; VB=INCONCLUSIVE; WB="B's own Vertex AI call was refused by VPC-SC even with the ingress rule: $VIOL" ;;
    *) VB=INCONCLUSIVE; WB="query to agent B gave no tool result ($OB)" ;;
  esac
  write_stage "$VB" "post B: $OB${WB:+; $WB}"

  sp="$(read_stage pre)"; reasons=""
  if [[ "$sp" == MISSING ]]; then sp=INCONCLUSIVE; reasons+="stage pre missing; "; fi
  [[ "$sp" == PASS ]] || reasons+="stage pre: $sp ($(jq -r '.note // empty' "$LZV_DIR/stages/pre.json" 2>/dev/null)); "
  [[ "$VA" == PASS ]] || reasons+="A: $WA; "
  [[ "$VB" == PASS ]] || reasons+="B: $WB; "
  final="$(verdict_merge "$sp" "$VA" "$VB")"
  [[ "$sp" == PASS ]] || final=INCONCLUSIVE   # without a working baseline the claim is not tested
  pnote="$(jq -r '.note // "not run"' "$LZV_DIR/stages/pre.json" 2>/dev/null || echo "not run")"
  write_result "$final" Enforced "${pnote}; post: A $OA; B $OB" "$reasons"
  ;;
esac
