#!/usr/bin/env bash
# T40b (v3 B1 complement): authoritative IAM (google_project_iam_binding, members = []) vs. the platform grant.
# Plan: plans/v3-harness-boundary-tests.md T40b. ONE run in a DEDICATED project (own infra-v3h state, never a
# project used by T40/T41/T43). Stages (human steps between, all via infra-v3h/terraform.tfvars):
#   pre    agent 1 deployed and working, t40b_authoritative=false, agent 2 not deployed
#   drift  tfvars: t40b_authoritative=true, NOT applied yet -> plan -detailed-exitcode (expect 2)
#   (human: terraform apply, then wait 7 minutes for IAM propagation)
#   call   agent 1 makes one model call (expect 403 PERMISSION_DENIED)
#   (human: deploy_agent_2=true, apply, t40b stays on; wait 5 minutes)
#   agent2 IAM + plan after agent 2; agent 2 model call; writes the result
# Model calls use ACTION=model MODE=bypass (direct genai call, so the answer is IAM's, not the harness guard's:
# the infra-v3h agents carry no approved-agent list).
# Never applies anything; the script only plans, reads IAM and queries the agents.
# shellcheck disable=SC2016
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib-v3h.sh
source "$(dirname "$0")/lib-v3h.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in pre|drift|call|agent2) ;; *) lzv_die "usage: T40b.sh pre|drift|call|agent2" ;; esac

LZV_SCOPE="folders/$(folder_id root)"
LZV_DOC_REFS=(
  "https://developer.hashicorp.com/terraform/cli/commands/plan"
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/agent-identity"
)
header T40b "B1 complement (Enforced for the 403 call, Configured for plan drift)" "Authoritative google_project_iam_binding for roles/aiplatform.agentDefaultAccess with members = []; control: agent 1 model call succeeds before the binding" \
  "\`plan\` detects drift (exit 2); applying \`members = []\` breaks agent 1's model calls (\`403\`); deploying agent 2 either re-introduces the drift or leaves agents broken. Tier: Enforced (for the 403 call) + Configured (for plan drift)." \
  "$STAGE"
note "plan claim B1; no resources are created by this script; no cleanup_trap registered"

v3h_init
LZV_SCOPE="projects/$V3H_PID"
ROLE="roles/aiplatform.agentDefaultAccess"
note "dedicated project: $V3H_PID (label $V3H_LABEL)"
A1="$(v3h_agent 1 id)"

case "$STAGE" in
pre)
  [[ -n "$A1" ]] || guard_abort "deploy agent 1 first (deploy_agent_1=true)"
  [[ -z "$(v3h_agent 2 id)" ]] || guard_abort "stage pre needs agent 2 not deployed"
  v3h_snapshot pre || { write_stage INCONCLUSIVE "pre: snapshot failed"; exit 0; }
  v3h_has_binding pre "$ROLE" "$V3H_PSET" || guard_abort "the platform binding is not on the project; deploy agent 1 and wait first"
  v3h_plan pre
  v3h_query "$A1" "ACTION=model MODE=bypass"
  if [[ "$Q_STATUS" == 200 && "$Q_BY" == none && "$V3H_PLAN_RC" == 0 ]]; then
    write_stage PASS "pre: agent 1 model call 200, plan exit 0, platform binding present"
  else
    write_stage INCONCLUSIVE "pre: baseline not clean (call status=$Q_STATUS refused_by=$Q_BY, plan exit $V3H_PLAN_RC)"
  fi
  ;;
drift)
  [[ -n "$A1" ]] || guard_abort "agent 1 is not deployed"
  [[ -d "$LZV_DIR/iam-pre" ]] || guard_abort "run stage pre first (same RUN_ID)"
  v3h_plan drift
  if [[ "$V3H_PLAN_RC" == 2 ]] && grep -q 'google_project_iam_binding\.t40b' <<<"$V3H_PLAN_CHANGES"; then
    write_stage PASS "drift: plan exit 2, changes: ${V3H_PLAN_CHANGES//$'\n'/; }"
  elif [[ "$V3H_PLAN_RC" == 0 ]]; then
    write_stage FAIL "drift: plan exit 0, no drift detected (is t40b_authoritative=true in terraform.tfvars?)"
  else
    write_stage INCONCLUSIVE "drift: plan exit $V3H_PLAN_RC, changes: ${V3H_PLAN_CHANGES//$'\n'/; }"
  fi
  ;;
call)
  [[ -n "$A1" ]] || guard_abort "agent 1 is not deployed"
  [[ "$(read_stage drift)" != MISSING ]] || guard_abort "run stage drift first"
  if [[ -n "${V3H_T40B_APPLY_400:-}" && -s "${V3H_T40B_APPLY_400}" ]]; then
    ERR400="$(tr '\n' ' ' <"$V3H_T40B_APPLY_400" | sed 's/  */ /g' | cut -c1-240)"
    note "apply of google_project_iam_binding.t40b (members = []) rejected by the API: $ERR400"
    v3h_snapshot call || { write_stage INCONCLUSIVE "call: snapshot failed"; write_result INCONCLUSIVE Enforced "snapshot failed" "IAM read failed"; exit 0; }
    PRESENT=0; v3h_has_binding call "$ROLE" "$V3H_PSET" && PRESENT=1
    write_stage INCONCLUSIVE "call: authoritative empty binding rejected by the API ($ERR400); platform binding present=$PRESENT"
    sp="$(read_stage pre)"; sd="$(read_stage drift)"
    sp="${sp/MISSING/INCONCLUSIVE}"; sd="${sd/MISSING/INCONCLUSIVE}"
    FINAL="$(verdict_merge "$sp" "$sd" INCONCLUSIVE)"
    write_result "$FINAL" Enforced "pre=$sp; drift=$sd (plan exit 2 expected); authoritative empty binding rejected by the API (platform binding present=$PRESENT)" "authoritative empty binding rejected by the API ($ERR400)"
    exit 0
  fi
  v3h_snapshot call || { write_stage INCONCLUSIVE "call: snapshot failed"; exit 0; }
  iam_diff pre call >/dev/null
  GONE=1; v3h_has_binding call "$ROLE" "$V3H_PSET" && GONE=0
  note "platform binding removed by the apply: $((GONE))"
  # IAM propagation can take minutes: retry while the call still answers 200 (5 attempts, 60 s apart).
  for i in 1 2 3 4 5; do
    v3h_query "$A1" "ACTION=model MODE=bypass"
    [[ "$Q_STATUS" == 200 ]] || break
    note "attempt $i: still 200, waiting for IAM propagation"
    (( i < 5 )) && sleep 60
  done
  if [[ "$GONE" == 1 && "$Q_STATUS" == 403 ]]; then
    write_stage PASS "call: binding removed, agent 1 model call 403 ($Q_ERR)"
  elif [[ "$GONE" == 0 ]]; then
    write_stage INCONCLUSIVE "call: the platform binding is still on the project (apply not done or binding kept)"
  elif [[ "$Q_STATUS" == 200 ]]; then
    write_stage FAIL "call: binding removed but agent 1 model call still 200 after 5 attempts"
  else
    write_stage INCONCLUSIVE "call: binding removed, call status=$Q_STATUS refused_by=$Q_BY err=${Q_ERR:-none}"
  fi
  ;;
agent2)
  A2="$(v3h_agent 2 id)"
  [[ -n "$A1" && -n "$A2" ]] || guard_abort "stage agent2 needs agents 1 and 2 deployed (deploy_agent_2=true)"
  [[ -d "$LZV_DIR/iam-call" ]] || guard_abort "run stage call first"
  v3h_snapshot agent2 || { write_stage INCONCLUSIVE "agent2: snapshot failed"; write_result INCONCLUSIVE Enforced "snapshot failed" "IAM read failed"; exit 0; }
  DIFF_LINES="$(iam_diff call agent2)"
  v3h_judge_diff "$DIFF_LINES"
  READDED="$J_EXPECTED"
  v3h_plan agent2
  PLAN2="$V3H_PLAN_RC"
  v3h_query "$A2" "ACTION=model MODE=bypass"
  ST2="$Q_STATUS"; ERR2="$Q_ERR"
  note "after agent 2: platform binding re-added=$READDED; plan exit=$PLAN2; agent 2 call status=$ST2"
  if [[ "$READDED" == 1 && "$PLAN2" == 2 ]]; then V2=PASS; W2=""; OBS="platform re-added the binding and plan drifts again (exit 2)"
  elif [[ "$READDED" == 0 && "$ST2" == 403 ]]; then V2=PASS; W2=""; OBS="binding not re-added; agent 2 model call 403 (agents left broken)"
  elif [[ "$READDED" == 1 && "$PLAN2" == 0 ]]; then V2=FAIL; W2="binding re-added but plan shows no drift (members = [] not enforced?)"; OBS="binding re-added, plan exit 0"
  elif [[ "$READDED" == 0 && "$ST2" == 200 ]]; then V2=FAIL; W2="agent 2 works without the platform binding present"; OBS="binding absent, agent 2 call 200"
  else V2=INCONCLUSIVE; W2="unclassified (re-added=$READDED plan=$PLAN2 status=$ST2 refused_by=$Q_BY)"; OBS="unclassified"; fi
  write_stage "$V2" "agent2: $OBS"
  sd="$(read_stage drift)"; sc="$(read_stage call)"; sp="$(read_stage pre)"
  FINAL="$(verdict_merge "$sp" "$sd" "$sc" "$V2")"
  WHY=""
  [[ "$sp" == PASS ]] || WHY+="stage pre: $sp; "
  [[ "$sd" == PASS ]] || WHY+="stage drift: $sd ($(jq -r '.note // empty' "$LZV_DIR/stages/drift.json" 2>/dev/null)); "
  [[ "$sc" == PASS ]] || WHY+="stage call: $sc ($(jq -r '.note // empty' "$LZV_DIR/stages/call.json" 2>/dev/null)); "
  [[ "$V2" == PASS ]] || WHY+="agent2: $W2; "
  [[ "$FINAL" == PASS ]] && WHY=""
  write_result "$FINAL" Enforced "pre=$sp; drift=$sd (plan exit 2 expected); call=$sc (403 expected); agent2: $OBS; agent 2 call error: ${ERR2:-none}" "$WHY"
  ;;
esac
