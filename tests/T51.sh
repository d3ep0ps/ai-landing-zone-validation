#!/usr/bin/env bash
# T51 (v3 B12): deny completeness for model access. Plan: plans/v3-harness-boundary-tests.md section 3b (pre-registered
# 2026-11-12, before this script). Runs in the T45 "on" window (DC1 deny on, exception for the approved agent).
# Non-approved agent (b_psci) and approved agent (a_psci, control), ACTION=routes: generateContent global and regional,
# streamGenerateContent, countTokens, OpenAI-compatible chat completions, batch prediction job create (input object
# missing; a created job is cancelled at once; human-approved 2026-11-12). Policy Troubleshooter attributes refusals
# (deny vs role never granted) for aiplatform.endpoints.predict and aiplatform.batchPredictionJobs.create.
# Reading rule: a route on which the APPROVED agent gets 404 (model or route not available) is NOT_TESTED for that route
# and does not decide the verdict (the regional host returned a model-not-found 404 in run 9, T31R).
# Falsified if: any route returns 200 for the non-approved agent, or a batch job is created.
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
  "https://docs.cloud.google.com/vertex-ai/docs/general/access-control"
  "https://docs.cloud.google.com/iam/docs/deny-access"
  "https://docs.cloud.google.com/policy-intelligence/docs/troubleshoot-access"
)
header T51 "B12 (Enforced)" "Model-access routes from the non-approved agent with the DC1 deny on; control: the approved agent on the same routes; Policy Troubleshooter attribution" \
  "No route allowed: predict-family routes (generateContent global/regional, streamGenerateContent, countTokens) refused by the deny; batch create refused because the role never granted it; chat completions refused (by deny or role, recorded). Falsified if: any route returns 200 or creates a job. Control: the approved agent gets 200 on the predict family; batch create refused for both (role). A route the approved agent cannot use (404) is NOT_TESTED for that route. Tier: Enforced. 2+ runs." \
  ""
note "plan claim B12; a batch job created by mistake would be cancelled by the agent at once; no cleanup_trap registered"

AID_N="$(agents_tf '.agent_v3.value.b_psci.id' 2>/dev/null)" || AID_N=""
AID_P="$(agents_tf '.agent_v3.value.a_psci.id' 2>/dev/null)" || AID_P=""
PRIN_N="$(agents_tf '.agent_v3.value.b_psci.identity' 2>/dev/null)" || PRIN_N=""
[[ -n "$AID_N" && "$AID_N" != null && -n "$AID_P" && "$AID_P" != null ]] || guard_abort "T51 needs a_psci and b_psci (T45 on window)"
run_capture gcloud iam policies list --attachment-point="cloudresourcemanager.googleapis.com/projects/$RT" --kind=denypolicies --format=json --billing-project="$(quota_project)"
[[ "$(v3h_json_last | jq '(if type == "array" then . else (.policies // []) end) | length' 2>/dev/null || echo 0)" -ge 1 ]] || guard_abort "T51 needs the DC1 deny policy on"

EMPTY_JSON="{}"
v3h_query "$AID_N" "ACTION=routes REGION=$LZV_REGION"; RN="$(jq -c '.probe.routes // {}' <<<"${Q_LINE:-$EMPTY_JSON}")"; HN="$Q_HAVE"
v3h_query "$AID_P" "ACTION=routes REGION=$LZV_REGION"; RP="$(jq -c '.probe.routes // {}' <<<"${Q_LINE:-$EMPTY_JSON}")"; HP="$Q_HAVE"
note "non-approved: $(jq -r 'to_entries | map("\(.key)=\(.value.status // "none")") | join(", ")' <<<"$RN")"
note "approved (control): $(jq -r 'to_entries | map("\(.key)=\(.value.status // "none")") | join(", ")' <<<"$RP")"
BATCH_NAME="$(jq -r '.batchPredictionJobs_create.created_name_tail // empty' <<<"$RN$RP" 2>/dev/null | head -1)"
[[ -z "$BATCH_NAME" ]] || note "WARNING: a batch job was created (tail $BATCH_NAME); cancel status non-approved=$(jq -r '.batchPredictionJobs_create.cancel.status // "n/a"' <<<"$RN") approved=$(jq -r '.batchPredictionJobs_create.cancel.status // "n/a"' <<<"$RP")"

PRINC="${PRIN_N#principal://}"
ts() {  # ts PERMISSION -> TS_ALLOW TS_DENY
  run_capture gcloud policy-intelligence troubleshoot-policy iam "//cloudresourcemanager.googleapis.com/projects/$RT" \
    --principal-email="$PRINC" --permission="$1" --format=json
  TS_ALLOW="$(v3h_json_last | jq -r '.allowPolicyExplanation.allowAccessState // "none"' 2>/dev/null)"
  TS_DENY="$(v3h_json_last | jq -r '.denyPolicyExplanation.denyAccessState // "none"' 2>/dev/null)"
}
ts aiplatform.endpoints.predict; PA="$TS_ALLOW"; PD="$TS_DENY"
ts aiplatform.batchPredictionJobs.create; BA="$TS_ALLOW"; BD="$TS_DENY"
note "troubleshooter (non-approved): endpoints.predict allow=$PA deny=$PD; batchPredictionJobs.create allow=$BA deny=$BD"

V=PASS; W=""; ROWS=""
for r in generateContent_global generateContent_regional streamGenerateContent_global countTokens_global chatCompletions_global batchPredictionJobs_create; do
  sn="$(jq -r --arg r "$r" '(.[$r].status // "none") | tostring' <<<"$RN")"
  sp="$(jq -r --arg r "$r" '(.[$r].status // "none") | tostring' <<<"$RP")"
  if [[ "$r" == batchPredictionJobs_create ]]; then
    by=role; [[ "$BD" == *DENIED* ]] && by=deny
    if [[ "$sn" == 200 ]]; then V=FAIL; W+="batch job created by the non-approved agent; "; by=allowed
    elif [[ "$sn" != 403 ]]; then [[ "$V" == FAIL ]] || V=INCONCLUSIVE; W+="batch create returned $sn; "; fi
  elif [[ "$sp" == 404 || "$sp" == 400 ]]; then by="not_tested (approved got $sp)"
  elif [[ "$sp" != 200 ]]; then by="no control ($sp)"; [[ "$V" == FAIL ]] || V=INCONCLUSIVE; W+="$r: approved agent got $sp; "
  elif [[ "$sn" == 200 ]]; then V=FAIL; by=allowed; W+="$r allowed for the non-approved agent; "
  elif [[ "$sn" == 403 ]]; then by=role; [[ "$PD" == *DENIED* ]] && by=deny
  else [[ "$V" == FAIL ]] || V=INCONCLUSIVE; by="unclear ($sn)"; W+="$r: non-approved got $sn; "; fi
  ROWS+="$r: non-approved=$sn approved=$sp -> $by; "
done
[[ "$HN" == 1 && "$HP" == 1 ]] || { V=INCONCLUSIVE; W="no result line from an agent (non-approved=$HN approved=$HP); $W"; }
note "routes: $ROWS"
write_result "$V" Enforced "$ROWS troubleshooter predict deny=$PD, batch allow=$BA" "${W%; }"
