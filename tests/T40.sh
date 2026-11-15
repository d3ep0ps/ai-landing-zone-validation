#!/usr/bin/env bash
# T40 (v3 B1): deploy-time IAM change invisible to Terraform. Plan: plans/v3-harness-boundary-tests.md T40.
# Stages: before | after. Fresh per-run project from infra-v3h (state infra-v3h/state/<run>.tfstate); the
# team Terraform there is additive (google_project_iam_member) and grants the agents nothing.
# Human step between stages: apply infra-v3h with deploy_agent_1=true (in terraform.tfvars), then wait 5
# minutes and export V3H_WAITED_5MIN=yes for stage after. The script never applies and deploys nothing.
# Falsified if: no binding is added, or `terraform plan` reports the change under google_project_iam_member.
# Audit log (doc check, notes/doc-verification-v3h.md): methodName and actor of a platform-initiated grant are
# NOT FOUND in docs, so the query is broad; nothing found = that sub-check INCONCLUSIVE, not FAIL.
# shellcheck disable=SC2016
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib-v3h.sh
source "$(dirname "$0")/lib-v3h.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in before|after) ;; *) lzv_die "usage: T40.sh before|after" ;; esac

LZV_SCOPE="folders/$(folder_id root)"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/agent-identity"
  "https://docs.cloud.google.com/resource-manager/docs/audit-logging"
  "https://developer.hashicorp.com/terraform/cli/commands/plan"
)
header T40 "B1 (Configured, read-back)" "Deploy-time IAM change is invisible to additive Terraform; control: before/after IAM snapshot and two plans" \
  "T40 (additive IAM, 3 runs): \`after.json\` contains one new binding, \`roles/aiplatform.agentDefaultAccess\` on \`principalSet://agents.global.org-ORG_ID.system.id.goog/attribute.platformContainer/aiplatform/projects/N\`; \`terraform plan\` returns exit code **0** (no changes) both before and after deploy; the audit log shows the change was made out-of-band by a Google-managed service identity, not the operator. Falsified if: no binding is added, or \`terraform plan\` reports the change under \`google_project_iam_member\`. Tier: Configured (read-back)." \
  "$STAGE"
note "plan claim B1; no resources are created by this script (the per-run project and agent are infra-v3h); no cleanup_trap registered"
note "limitation: the audit-log sub-check depends on an unverified methodName/actor; see header"

v3h_init
LZV_SCOPE="projects/$V3H_PID"
note "per-run project: $V3H_PID (label $V3H_LABEL); expected principalSet: $V3H_PSET"
note "how agent 1 is deployed: infra-v3h Terraform module (geap-agent-runtime, source tarball infra-v3h/build/source.tar.gz); keep identical across runs"

case "$STAGE" in
before)
  [[ -z "$(v3h_agent 1 id)" ]] || guard_abort "stage before needs agent 1 not deployed (deploy_agent_1=false)"
  v3h_snapshot before || { write_stage INCONCLUSIVE "before: snapshot failed"; exit 0; }
  v3h_plan before
  if [[ "$V3H_PLAN_RC" == 0 ]]; then
    write_stage PASS "before: plan exit 0, snapshot written"
  else
    write_stage INCONCLUSIVE "before: plan exit $V3H_PLAN_RC (changes: ${V3H_PLAN_CHANGES//$'\n'/; })"
  fi
  ;;
after)
  [[ "${V3H_WAITED_5MIN:-}" == yes ]] || guard_abort "wait 5 minutes after the deploy, then export V3H_WAITED_5MIN=yes"
  [[ -n "$(v3h_agent 1 id)" ]] || guard_abort "stage after needs agent 1 deployed (deploy_agent_1=true)"
  [[ -d "$LZV_DIR/iam-before" ]] || guard_abort "run stage before first (same RUN_ID)"
  sb="$(read_stage before)"; [[ "$sb" == MISSING ]] && sb=INCONCLUSIVE
  SINCE="$(stage_ts before)"; [[ -n "$SINCE" ]] || guard_abort "stage before has no timestamp"

  # 1. IAM diff
  if ! v3h_snapshot after; then
    write_stage INCONCLUSIVE "after: snapshot failed"
    write_result INCONCLUSIVE Configured "after snapshot failed" "an IAM read failed; the diff would be partial"
    exit 0
  fi
  DIFF_LINES="$(iam_diff before after)"
  v3h_judge_diff "$DIFF_LINES"
  note "added=$J_ADDED expected_binding_added=$J_EXPECTED extra=[${J_EXTRA:-none}] removed=[${J_REMOVED:-none}]"
  if [[ -n "$J_EXTRA" ]]; then VB=FAIL; WB="added bindings not on the pre-registered list: $J_EXTRA"
  elif [[ "$J_EXPECTED" == 1 && "$J_ADDED" == 1 ]]; then VB=PASS; WB=""
  elif [[ "$J_ADDED" == 0 ]]; then
    if v3h_has_binding before roles/aiplatform.agentDefaultAccess "$V3H_PSET"; then
      VB=INCONCLUSIVE; WB="binding already present before the deploy (not added by agent 1)"
    else VB=FAIL; WB="no binding added by the deploy"; fi
  else VB=INCONCLUSIVE; WB="unexpected diff shape (added=$J_ADDED, expected binding added=$J_EXPECTED)"; fi

  # 2. plan after the deploy
  v3h_plan after
  PV=PASS; PW=""
  if [[ "$V3H_PLAN_RC" == 0 ]]; then :
  elif [[ "$V3H_PLAN_RC" == 2 ]] && grep -q 'google_project_iam_member' <<<"$V3H_PLAN_CHANGES"; then
    PV=FAIL; PW="plan reports a change under google_project_iam_member: ${V3H_PLAN_CHANGES//$'\n'/; }"
  elif [[ "$V3H_PLAN_RC" == 2 ]]; then
    PV=INCONCLUSIVE; PW="plan exit 2 for other resources (not the IAM members): ${V3H_PLAN_CHANGES//$'\n'/; }"
  else PV=INCONCLUSIVE; PW="plan exit $V3H_PLAN_RC"; fi

  # 3. audit log (broad: methodName =~ SetIamPolicy since the before stage, request mentioning agentDefaultAccess)
  OPERATOR="$(gcloud config get account 2>/dev/null)"
  run_capture gcloud logging read \
    'log_id("cloudaudit.googleapis.com/activity") AND protoPayload.methodName=~"(?i)setiampolicy" AND timestamp>="'"$SINCE"'"' \
    --project="$V3H_PID" --limit=100 --format=json
  v3h_json_last >"$LZV_DIR/audit-setiampolicy.json"
  TOTAL="$(jq 'length' "$LZV_DIR/audit-setiampolicy.json" 2>/dev/null || echo '?')"
  HITS="$(jq -c '[.[]? | select(tojson | test("agentDefaultAccess")) | {t:.timestamp, m:.protoPayload.methodName, s:.protoPayload.serviceName, email:(.protoPayload.authenticationInfo.principalEmail // ""), subject:(.protoPayload.authenticationInfo.principalSubject // "")}]' "$LZV_DIR/audit-setiampolicy.json" 2>/dev/null || echo '[]')"
  if [[ "$(jq 'length' <<<"$HITS")" == 0 ]]; then
    run_capture gcloud logging read '"agentDefaultAccess" AND timestamp>="'"$SINCE"'"' --project="$V3H_PID" --limit=20 --format=json
    v3h_json_last >"$LZV_DIR/audit-freetext.json"
    HITS="$(jq -c '[.[]? | {t:.timestamp, log:.logName, m:(.protoPayload.methodName // ""), email:(.protoPayload.authenticationInfo.principalEmail // ""), subject:(.protoPayload.authenticationInfo.principalSubject // "")}]' "$LZV_DIR/audit-freetext.json" 2>/dev/null || echo '[]')"
    note "fallback free-text query used (no SetIamPolicy entry mentioned agentDefaultAccess)"
  fi
  NHITS="$(jq 'length' <<<"$HITS")"
  note "audit: SetIamPolicy entries since $SINCE: $TOTAL; entries mentioning agentDefaultAccess: $NHITS; first: $(jq -c '.[0] // "none"' <<<"$HITS")"
  ACTOR="$(jq -r '.[0] | (.email // "") + (if (.email // "") == "" then (.subject // "") else "" end)' <<<"$HITS" 2>/dev/null)"
  if [[ "$NHITS" == 0 ]]; then
    AV=INCONCLUSIVE; AW="grant not visible as an audit entry in the project log (methodName/actor not documented); no entry found"
  elif [[ -n "$ACTOR" && "$ACTOR" == "$OPERATOR" ]]; then
    AV=FAIL; AW="audit entry actor is the operator account, not a Google-managed identity"
  else
    AV=PASS; AW=""
    [[ -n "$ACTOR" ]] || note "audit entry found but no principalEmail/principalSubject; actor unknown, recorded as found"
  fi

  write_stage "$VB" "after: IAM diff added=$J_ADDED expected=$J_EXPECTED"
  FINAL="$(verdict_merge "$sb" "$VB" "$PV" "$AV")"
  WHY=""
  [[ "$sb" == PASS ]] || WHY+="stage before: $sb ($(jq -r '.note // empty' "$LZV_DIR/stages/before.json" 2>/dev/null)); "
  [[ "$VB" == PASS ]] || WHY+="IAM diff: $WB; "
  [[ "$PV" == PASS ]] || WHY+="plan after: $PW; "
  [[ "$AV" == PASS ]] || WHY+="audit: $AW; "
  [[ "$FINAL" == PASS ]] && WHY=""
  write_result "$FINAL" Configured "diff: added=$J_ADDED (expected binding=$J_EXPECTED, extra=[${J_EXTRA:-none}]); stage before=$sb (plan before), plan after exit $V3H_PLAN_RC; audit entries mentioning the role=$NHITS, actor=${ACTOR:-none found}" "$WHY"
  ;;
esac
