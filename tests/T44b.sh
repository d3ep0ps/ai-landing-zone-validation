#!/usr/bin/env bash
# T44b (v3 B5 split, finding F4): session creation decided by deploy order. Plan: plans/v3-harness-boundary-tests.md
# section 3b (pre-registered 2026-11-12, before this script). Agents v3a (deployed BEFORE enforcement) and v3b (deployed
# AFTER), one tarball. Per agent: one async_create_session (no model call, no egress) by the operator.
#   noingress  perimeter enforced, no agent identity in an ingress rule
#   ingress1   about 1 min after the ingress apply (after the canary): OBSERVATION only (propagation)
#   ingress15  >= 15 min after the ingress apply (V3H_WAITED_15MIN=yes); writes the result
# Control at each point: the operator's reasoningEngines.list in the runtime project (200).
# Falsified if: A and B behave the same without the ingress rule, or A is still refused at +15 min with its identity in
# the ingress rule.
# shellcheck disable=SC2016
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib-v3h.sh
source "$(dirname "$0")/lib-v3h.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in noingress|ingress1|ingress15) ;; *) lzv_die "usage: T44b.sh noingress|ingress1|ingress15" ;; esac

RT="$(project_id runtime)"; RT_NUM="$(project_number runtime)"
LZV_SCOPE="projects/$RT"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/vpc-service-controls/docs/supported-identities"
  "https://docs.cloud.google.com/vpc-service-controls/docs/ingress-egress-rules"
)
header T44b "B5 (Enforced)" "Session creation on an agent deployed before (A) vs after (B) perimeter enforcement, without and with the agent ingress rule; control: operator reasoningEngines.list 200" \
  "noingress: A refused with HTTP 403 carrying a VPC-SC unique identifier, B 200. ingress +15 min: A 200, B 200. The +1 min cell is recorded only. Falsified if: A and B behave the same without the ingress rule, or A is still refused at +15 min with its identity in the ingress rule. Tier: Enforced. 3 runs." \
  "$STAGE"
note "plan claim B5 (split, F4); no resources are created by this script; no cleanup_trap registered"

AID_A="$(agents_tf '.agent_v3.value.a.id' 2>/dev/null)" || AID_A=""
AID_B="$(agents_tf '.agent_v3.value.b.id' 2>/dev/null)" || AID_B=""
PRIN_A="$(agents_tf '.agent_v3.value.a.identity' 2>/dev/null)" || PRIN_A=""
PRIN_B="$(agents_tf '.agent_v3.value.b.identity' 2>/dev/null)" || PRIN_B=""
[[ -n "$AID_A" && "$AID_A" != null && -n "$AID_B" && "$AID_B" != null ]] || guard_abort "agents v3a and v3b must both be deployed"

run_capture gcloud access-context-manager policies list --organization="$(org_id)" --format=json
POL="$(v3h_json_last | jq -r --arg f "folders/$(folder_id root)" '[.[] | select((.scopes // []) | index($f))][0].name // empty' | sed 's#^accessPolicies/##')"
[[ -n "$POL" ]] || guard_abort "no access policy scoped to the test folder"
run_capture gcloud access-context-manager perimeters describe lzv_ai --policy="$POL" --format=json
PERIM="$(v3h_json_last)"
IN_STATUS="$(jq -r --arg p "projects/$RT_NUM" '[(.status.resources // [])[] | select(. == $p)] | length' <<<"$PERIM")"
ING_A=0; ING_B=0
jq -e --arg p "$PRIN_A" '[(.status.ingressPolicies // [])[] | (.ingressFrom.identities // [])[] | select(. == $p)] | length > 0' <<<"$PERIM" >/dev/null && ING_A=1
jq -e --arg p "$PRIN_B" '[(.status.ingressPolicies // [])[] | (.ingressFrom.identities // [])[] | select(. == $p)] | length > 0' <<<"$PERIM" >/dev/null && ING_B=1
note "perimeter: runtime in status=$IN_STATUS; A in ingress=$ING_A, B in ingress=$ING_B"
[[ "$IN_STATUS" == 1 ]] || guard_abort "T44b needs the runtime project in the enforced perimeter"
case "$STAGE" in
  noingress) [[ "$ING_A" == 0 && "$ING_B" == 0 ]] || guard_abort "stage noingress needs no agent identity in an ingress rule" ;;
  ingress1)  [[ "$ING_A" == 1 && "$ING_B" == 1 ]] || guard_abort "stage ingress1 needs both identities in the ingress rule" ;;
  ingress15) [[ "$ING_A" == 1 && "$ING_B" == 1 ]] || guard_abort "stage ingress15 needs both identities in the ingress rule"
             [[ "${V3H_WAITED_15MIN:-}" == yes ]] || guard_abort "stage ingress15 runs >= 15 min after the ingress apply (V3H_WAITED_15MIN=yes)" ;;
esac

# session ID -> S_CODE (HTTP), S_VPCSC (1 if the body carries a VPC-SC unique identifier)
session() {
  local id="$1" region; region="${id#*/locations/}"; region="${region%%/*}"
  export LZV_URL="https://${region}-aiplatform.googleapis.com/v1/${id}:query"
  run_capture_sh 'printf "Authorization: Bearer %s\n" "$(gcloud auth print-access-token)" | curl -sS --max-time 60 -H @- -H "Content-Type: application/json" -X POST "$LZV_URL" -d "{\"class_method\":\"async_create_session\",\"input\":{\"user_id\":\"lzv-t44b\"}}" -w "\nHTTP %{http_code}\n"'
  S_CODE="$(sed -n 's/^HTTP //p' "$LZV_LAST_OUT" | tail -1)"; S_VPCSC=0
  grep -q vpcServiceControlsUniqueIdentifier "$LZV_LAST_OUT" && S_VPCSC=1
}
session "$AID_A"; A_CODE="$S_CODE"; A_VPCSC="$S_VPCSC"
session "$AID_B"; B_CODE="$S_CODE"; B_VPCSC="$S_VPCSC"
export LZV_URL="https://${LZV_REGION}-aiplatform.googleapis.com/v1/projects/$RT/locations/$LZV_REGION/reasoningEngines?pageSize=1"
run_capture_sh 'curl -sS --max-time 60 -o /dev/null -w "HTTP %{http_code}\n" -H "Authorization: Bearer $(gcloud auth print-access-token)" "$LZV_URL"'
CTL="$(sed -n 's/^HTTP //p' "$LZV_LAST_OUT" | tail -1)"
note "$STAGE: A session HTTP=$A_CODE vpcsc=$A_VPCSC; B session HTTP=$B_CODE vpcsc=$B_VPCSC; control (operator list)=$CTL"

V=INCONCLUSIVE; W=""
if [[ "$CTL" != 200 ]]; then W="control failed: operator reasoningEngines.list HTTP $CTL"
else
  case "$STAGE" in
    noingress)
      if [[ "$A_CODE" == 403 && "$A_VPCSC" == 1 && "$B_CODE" == 200 ]]; then V=PASS
      elif [[ "$A_CODE" == "$B_CODE" ]]; then V=FAIL; W="A and B behave the same without the ingress rule (both HTTP $A_CODE)"
      else W="unexpected pair (A=$A_CODE vpcsc=$A_VPCSC, B=$B_CODE)"; fi ;;
    ingress1) V=PASS; W="observation only" ;;
    ingress15)
      if [[ "$A_CODE" == 200 && "$B_CODE" == 200 ]]; then V=PASS
      elif [[ "$A_CODE" == 403 && "$A_VPCSC" == 1 ]]; then V=FAIL; W="A still refused by VPC-SC at +15 min with its identity in the ingress rule"
      else W="unexpected pair (A=$A_CODE vpcsc=$A_VPCSC, B=$B_CODE)"; fi ;;
  esac
fi
write_stage "$V" "$STAGE: A=$A_CODE (vpcsc=$A_VPCSC) B=$B_CODE (vpcsc=$B_VPCSC) control=$CTL${W:+; $W}"

if [[ "$STAGE" == ingress15 ]]; then
  SN="$(read_stage noingress)"; SN="${SN/MISSING/INCONCLUSIVE}"
  FINAL="$(verdict_merge "$SN" "$V")"
  WHY=""
  [[ "$SN" == PASS ]] || WHY+="noingress: $SN ($(jq -r '.note // empty' "$LZV_DIR/stages/noingress.json" 2>/dev/null)); "
  [[ "$V" == PASS ]] || WHY+="ingress15: $W; "
  [[ "$FINAL" == PASS ]] && WHY=""
  I1="$(jq -r '.note // "not run"' "$LZV_DIR/stages/ingress1.json" 2>/dev/null || echo "not run")"
  write_result "$FINAL" Enforced "noingress: $(jq -r '.note // empty' "$LZV_DIR/stages/noingress.json" 2>/dev/null); ingress +1 min (observation): $I1; ingress +15 min: A=$A_CODE B=$B_CODE" "$WHY"
fi
