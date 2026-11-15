#!/usr/bin/env bash
# T19 (TS1): IAM diff around the deployment of one agent. Stages: before | after.
# The human deploys agent A only (deploy_agent_a=true, deploy_agent_b=false) between stages.
# Pre-registered allow list: exactly one added binding, roles/aiplatform.agentDefaultAccess on
# the project agent principalSet at the runtime project. Appendix D T19 does not allow
# roles/aiplatform.agentContextEditor, so any other added binding is a finding (FAIL).
# Scopes: runtime, mcp, data projects, test root folder, ai_prod folder, project deny policies.
# Organization-level allow policy is not read (operator has no need; see iam_snapshot in lib.sh).
# shellcheck disable=SC2016
set -u
source "$(dirname "$0")/lib.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in before|after) ;; *) lzv_die "usage: T19.sh before|after" ;; esac

LZV_SCOPE="folders/$(folder_id root)"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/agent-identity"
  "https://docs.cloud.google.com/iam/docs/deny-access"
)
header T19 "TS1" "IAM bindings added by the platform when one agent is deployed" \
  "The only added bindings are those on the pre-registered list (from v1: \`roles/aiplatform.agentDefaultAccess\` on the project principalSet). Any other added binding = finding" \
  "$STAGE"
note "no resources are created by this script; no cleanup_trap registered"
note "limitation: get-iam-policy returns direct bindings only at each resource; organization allow policy not read"

agent_state() {  # sets A_DEPLOYED, B_DEPLOYED (0/1) from infra/agents outputs
  local a b
  a="$(agents_tf '.agent_a.value.id // empty' 2>/dev/null)" || a=""
  b="$(agents_tf '.agent_b.value.id // empty' 2>/dev/null)" || b=""
  A_DEPLOYED=0; B_DEPLOYED=0
  [[ -n "$a" ]] && A_DEPLOYED=1
  [[ -n "$b" ]] && B_DEPLOYED=1
  agents_tf '.' >/dev/null 2>&1 || guard_abort "terraform output in infra/agents is unreadable"  # '{}' (never applied) means no agents (fixed before first T19 stage, 2026-10-25)
  note "agents deployed: A=$A_DEPLOYED B=$B_DEPLOYED"
}

agent_state
case "$STAGE" in
before)
  [[ "$A_DEPLOYED" == 0 && "$B_DEPLOYED" == 0 ]] || guard_abort "stage before needs no agents deployed (deploy_agent_a=false, deploy_agent_b=false)"
  if iam_snapshot before; then
    write_stage PASS "before: snapshot written, no agents deployed"
  else
    write_stage INCONCLUSIVE "before: snapshot incomplete"
  fi
  ;;
after)
  [[ "$A_DEPLOYED" == 1 && "$B_DEPLOYED" == 0 ]] || guard_abort "stage after needs agent A only (deploy_agent_a=true, deploy_agent_b=false)"
  [[ -d "$LZV_DIR/iam-before" ]] || guard_abort "run stage before first (same RUN_ID)"
  sp="$(read_stage before)"
  if [[ "$sp" == MISSING ]]; then sp=INCONCLUSIVE; fi
  if ! iam_snapshot after; then
    write_stage INCONCLUSIVE "after: snapshot incomplete"
    write_result INCONCLUSIVE Configured "after snapshot incomplete" "an IAM read failed; the diff would be partial"
    exit 0
  fi
  DIFF_LINES="$(iam_diff before after)"
  RT_NUM="$(project_number runtime)"
  WANT_ROLE="roles/aiplatform.agentDefaultAccess"
  WANT_MEMBER="principalSet://agents.global.org-$(org_id).system.id.goog/attribute.platformContainer/aiplatform/projects/${RT_NUM}"
  ADDED_N="$(jq -s '[.[] | select(.change == "added")] | length' <<<"$DIFF_LINES")"
  EXPECTED_N="$(jq -s --arg r "$WANT_ROLE" --arg m "$WANT_MEMBER" '[.[] | select(.change == "added" and .scope == "project-runtime" and .role == $r and .member == $m)] | length' <<<"$DIFF_LINES")"
  EXTRA="$(jq -sr --arg r "$WANT_ROLE" --arg m "$WANT_MEMBER" '[.[] | select(.change == "added" and (.scope == "project-runtime" and .role == $r and .member == $m | not)) | "\(.scope) \(.role) \(.member)"] | join("; ")' <<<"$DIFF_LINES")"
  REMOVED="$(jq -sr '[.[] | select(.change == "removed") | "\(.scope) \(.role) \(.member)"] | join("; ")' <<<"$DIFF_LINES")"
  note "added=$ADDED_N expected_binding_added=$EXPECTED_N extra=[${EXTRA:-none}] removed=[${REMOVED:-none}]"
  if [[ -n "$EXTRA" ]]; then
    V=FAIL; WHY="finding: bindings added that are not on the pre-registered list: $EXTRA"
  elif [[ "$EXPECTED_N" == 1 && "$ADDED_N" == 1 ]]; then
    V=PASS; WHY=""
  elif [[ "$ADDED_N" == 0 ]]; then
    # D3 text: only added bindings on the list are allowed; zero added bindings satisfies it.
    # Record whether the expected binding already existed before the deploy (Opus review 2026-10-25).
    if grep -rqF "$WANT_MEMBER" "$LZV_DIR/iam-before" 2>/dev/null; then PRE="present before the deploy"; else PRE="absent before and after the deploy"; fi
    V=PASS; WHY=""
    note "no bindings added; expected binding $PRE"
  else
    V=INCONCLUSIVE; WHY="unexpected diff shape (added=$ADDED_N, expected binding added=$EXPECTED_N)"
  fi
  [[ -z "$REMOVED" ]] || WHY+="${WHY:+; }removed bindings (reported): $REMOVED"
  write_stage "$V" "after: added=$ADDED_N extra=[${EXTRA:-none}]"
  FINAL="$V"
  if [[ "$sp" != PASS ]]; then
    [[ "$FINAL" == FAIL ]] || FINAL=INCONCLUSIVE
    WHY+="${WHY:+; }stage before: $sp"
  fi
  # Removed bindings alone do not change a PASS, but they are recorded in actual and reason.
  [[ "$FINAL" == PASS ]] && WHY=""
  write_result "$FINAL" Configured "added=$ADDED_N (expected binding present=$EXPECTED_N); extra=[${EXTRA:-none}]; removed=[${REMOVED:-none}]" "$WHY"
  ;;
esac
