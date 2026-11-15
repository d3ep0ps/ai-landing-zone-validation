#!/usr/bin/env bash
# T41 (v3 B2): the deploy-time grant covers every agent. Plan: plans/v3-harness-boundary-tests.md T41.
# Run after T40 in the same per-run project (agent 1 deployed, platform binding present).
# Stages: before | after. Human step between stages: infra-v3h deploy_agent_2=true (same artifact, zero roles),
# apply, wait 5 minutes, export V3H_WAITED_5MIN=yes.
# Policy Troubleshooter (notes/doc-verification-v3h.md T41): --principal-email takes the agent identity WITHOUT the
# principal:// prefix. An Unknown result for the principalSet binding is a documented limitation: that sub-check
# is INCONCLUSIVE, not a falsification. The model call by agent 2 is the Enforced part.
# Falsified if: the call is refused, or a per-agent binding appears.
# shellcheck disable=SC2016
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib-v3h.sh
source "$(dirname "$0")/lib-v3h.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in before|after) ;; *) lzv_die "usage: T41.sh before|after" ;; esac

LZV_SCOPE="folders/$(folder_id root)"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/policy-intelligence/docs/troubleshoot-access"
  "https://docs.cloud.google.com/iam/docs/auth-agent-own-identity"
)
header T41 "B2 (Enforced for the call, Configured for the Troubleshooter)" "Agent 2 (same artifact, zero roles) is covered by the project-wide principalSet grant; control: IAM diff and agent 2 model call" \
  "no new binding; Troubleshooter shows access granted through the principal-set binding; agent 2's call succeeds. Falsified if: the call is refused, or a per-agent binding appears. Tier: Enforced for the call (an allowed action, recorded as such), Configured for the Troubleshooter." \
  "$STAGE"
note "plan claim B2; no resources are created by this script; no cleanup_trap registered"
note "limitation: the call is an allowed action (positive result); Troubleshooter cannot evaluate attribute-based principalSet bindings for non-standard agent subjects (Unknown)"

v3h_init
LZV_SCOPE="projects/$V3H_PID"
ROLE="roles/aiplatform.agentDefaultAccess"
note "per-run project: $V3H_PID (label $V3H_LABEL)"

case "$STAGE" in
before)
  [[ -n "$(v3h_agent 1 id)" ]] || guard_abort "stage before needs agent 1 deployed (T40 done)"
  [[ -z "$(v3h_agent 2 id)" ]] || guard_abort "stage before needs agent 2 not deployed"
  v3h_snapshot before || { write_stage INCONCLUSIVE "before: snapshot failed"; exit 0; }
  if v3h_has_binding before "$ROLE" "$V3H_PSET"; then
    write_stage PASS "before: snapshot written, platform binding present, agent 2 not deployed"
  else
    write_stage INCONCLUSIVE "before: platform binding absent (T40 not done or binding removed)"
  fi
  ;;
after)
  [[ "${V3H_WAITED_5MIN:-}" == yes ]] || guard_abort "wait 5 minutes after the deploy, then export V3H_WAITED_5MIN=yes"
  A2="$(v3h_agent 2 id)"; P2="$(v3h_agent 2 identity)"
  [[ -n "$A2" && -n "$P2" ]] || guard_abort "stage after needs agent 2 deployed (deploy_agent_2=true)"
  [[ -d "$LZV_DIR/iam-before" ]] || guard_abort "run stage before first (same RUN_ID)"
  sb="$(read_stage before)"; [[ "$sb" == MISSING ]] && sb=INCONCLUSIVE
  note "agent 2: $A2; identity: $P2"

  # 1. IAM diff: expect nothing new (no per-agent binding)
  if ! v3h_snapshot after; then
    write_stage INCONCLUSIVE "after: snapshot failed"
    write_result INCONCLUSIVE Enforced "after snapshot failed" "an IAM read failed; the diff would be partial"
    exit 0
  fi
  DIFF_LINES="$(iam_diff before after)"
  v3h_judge_diff "$DIFF_LINES"
  if [[ "$J_ADDED" == 0 ]]; then DV=PASS; DW=""
  else DV=FAIL; DW="binding(s) added by the deploy of agent 2: ${J_EXTRA:-the platform principalSet again}"; fi
  note "added=$J_ADDED removed=[${J_REMOVED:-none}]"

  # 2. Policy Troubleshooter (principal without the principal:// prefix)
  PRINC="${P2#principal://}"
  run_capture gcloud policy-intelligence troubleshoot-policy iam "//cloudresourcemanager.googleapis.com/projects/$V3H_PID" \
    --principal-email="$PRINC" --permission=aiplatform.endpoints.predict --format=json
  TRC="$LZV_LAST_RC"
  v3h_json_last >"$LZV_DIR/troubleshooter.json"
  ACCESS="$(jq -r '.access // .overallAccessState // empty' "$LZV_DIR/troubleshooter.json" 2>/dev/null)"
  note "troubleshooter: exit=$TRC access=${ACCESS:-none}"
  if [[ "$TRC" != 0 ]]; then
    TV=INCONCLUSIVE; TW="troubleshooter command failed (exit $TRC): $(tr '\n' ' ' <"$LZV_LAST_OUT" | cut -c1-200)"
  elif [[ "$ACCESS" == GRANTED || "$ACCESS" == CAN_ACCESS ]]; then TV=PASS; TW=""
  elif grep -Eqi 'unknown' <<<"$ACCESS" || grep -Eqi 'UNKNOWN' "$LZV_DIR/troubleshooter.json"; then
    TV=INCONCLUSIVE; TW="Troubleshooter returned Unknown for the principalSet binding (documented limitation; access=${ACCESS:-none})"
  elif [[ "$ACCESS" == NOT_GRANTED || "$ACCESS" == CANNOT_ACCESS ]]; then
    TV=FAIL; TW="Troubleshooter says access not granted (access=$ACCESS)"
  else TV=INCONCLUSIVE; TW="unrecognised Troubleshooter result (access=${ACCESS:-none})"; fi

  # 3. agent 2 model call (direct genai call: the answer is IAM's)
  v3h_query "$A2" "ACTION=model MODE=bypass"
  if [[ "$Q_HAVE" == 1 && "$Q_STATUS" == 200 && "$Q_BY" == none ]]; then CV=PASS; CW=""
  elif [[ "$Q_HAVE" == 1 && "$Q_BY" != none ]]; then CV=FAIL; CW="agent 2 call refused (refused_by=$Q_BY status=$Q_STATUS): ${Q_ERR:-no text}"
  else CV=INCONCLUSIVE; CW="no result line from agent 2 (http_rc=$Q_RC)"; fi

  write_stage "$DV" "after: diff added=$J_ADDED"
  FINAL="$(verdict_merge "$sb" "$DV" "$TV" "$CV")"
  WHY=""
  [[ "$sb" == PASS ]] || WHY+="stage before: $sb; "
  [[ "$DV" == PASS ]] || WHY+="diff: $DW; "
  [[ "$TV" == PASS ]] || WHY+="troubleshooter (Configured): $TW; "
  [[ "$CV" == PASS ]] || WHY+="call: $CW; "
  [[ "$FINAL" == PASS ]] && WHY=""
  write_result "$FINAL" Enforced "diff added=$J_ADDED; troubleshooter access=${ACCESS:-none} (exit $TRC); agent 2 call status=$Q_STATUS refused_by=$Q_BY" "$WHY"
  ;;
esac
