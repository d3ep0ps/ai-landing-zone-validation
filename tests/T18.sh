#!/usr/bin/env bash
# T18: DC1 deny policy on aiplatform.googleapis.com/endpoints.predict for project agents,
# exception for approved agent(s). Stages: pre | post. The result is written by `post`.
# The human applies Terraform between stages; this script never applies.
#   pre : agents A and B deployed, enable_dc1_deny=false. Both agents must answer.
#   post: enable_dc1_deny=true, dc1_approved_agent_principals=[agent A principal],
#         at least 10 minutes after the deny policy createTime. B refused, A answers.
# shellcheck disable=SC2016
set -u
source "$(dirname "$0")/lib.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in pre|post) ;; *) lzv_die "usage: T18.sh pre|post" ;; esac

LZV_SCOPE="projects/$(project_id runtime)"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/iam/docs/deny-access"
  "https://docs.cloud.google.com/iam/docs/principal-identifiers"
  "https://docs.cloud.google.com/iam/docs/permission-error-messages"
)
header T18 "R2 / I3" "Agent-identity inference restricted by IAM deny policy (DC1)" \
  "Before the deny policy: the non-approved agent's call succeeds. After it (wait 10 min): the non-approved agent's call refused with \`PERMISSION_DENIED\` (deny text is generic); the approved agent's identical call succeeds; \`gcloud iam policies list --kind=denypolicies\` shows the policy. Policy Analyzer is not used (allow policies only)" \
  "$STAGE"
note "no resources are created by this script (agents and the deny policy are Terraform-managed); no cleanup_trap registered"
note "limitation: deny cause is inferred from the paired control (approved agent succeeds) and the listed policy; the generic PERMISSION_DENIED text does not name the deny policy"

RT="$(project_id runtime)"
POLICY_ID="lzv-dc1-deny-agent-predict"

AID_A="$(agents_tf '.agent_a.value.id' 2>/dev/null)" || AID_A=""
AID_B="$(agents_tf '.agent_b.value.id' 2>/dev/null)" || AID_B=""
[[ -n "$AID_A" && -n "$AID_B" ]] || guard_abort "deploy agents A and B first (deploy_agent_a=true, deploy_agent_b=true)"
PRIN_A="$(agents_tf '.agent_a.value.identity' 2>/dev/null)" || PRIN_A=""
PRIN_B="$(agents_tf '.agent_b.value.identity' 2>/dev/null)" || PRIN_B=""
note "agent A id: $AID_A"
note "agent B id: $AID_B"
note "agent A principal: $PRIN_A"
note "agent B principal: $PRIN_B"
[[ "$PRIN_A" == principal://* ]] || note "WARNING: agent A identity output is not a principal:// string; check infra/agents output before setting dc1_approved_agent_principals"

# deny_policy_state -> sets DP_N (0/1 policy present), DP_CREATE (epoch seconds), DP_EXC (exceptionPrincipals)
deny_policy_state() {
  run_capture gcloud iam policies list --attachment-point="cloudresourcemanager.googleapis.com/projects/$RT" \
    --kind=denypolicies --format=json --billing-project="$(quota_project)"
  [[ "$LZV_LAST_RC" == 0 ]] || guard_abort "cannot list deny policies (exit $LZV_LAST_RC)"
  # gcloud returns {"policies": [...]} with metadata only (no rules); rules come from `policies get`.
  # (Fixed 2026-10-25 after the first post attempt aborted on this parser, before any agent query.)
  local j; j="$(sed -n '/^[[{]/,$p' "$LZV_LAST_OUT")"
  [[ -n "$j" ]] || j='{}'
  local sel='(if type == "array" then . else (.policies // []) end) | [.[] | select((.name | split("/") | last) == $id)]'
  DP_N="$(jq --arg id "$POLICY_ID" "$sel | length" <<<"$j")"
  DP_CREATE="$(jq -r --arg id "$POLICY_ID" "$sel | .[0].createTime // empty
    | if . == \"\" then \"\" else (sub(\"\\\\.[0-9]+Z\$\"; \"Z\") | fromdateiso8601 | tostring) end" <<<"$j")"
  DP_EXC=""
  if [[ "$DP_N" == 1 ]]; then
    run_capture gcloud iam policies get "$POLICY_ID" --attachment-point="cloudresourcemanager.googleapis.com/projects/$RT" \
      --kind=denypolicies --format=json --billing-project="$(quota_project)"
    [[ "$LZV_LAST_RC" == 0 ]] || guard_abort "cannot read deny policy $POLICY_ID (exit $LZV_LAST_RC)"
    DP_EXC="$(sed -n '/^[[{]/,$p' "$LZV_LAST_OUT" | jq -r '[.rules[]?.denyRule.exceptionPrincipals[]?] | join(", ")')"
  fi
  [[ "$DP_N" =~ ^[01]$ ]] || guard_abort "cannot parse deny policy list"
  note "deny policy $POLICY_ID present=$DP_N createTime_epoch=${DP_CREATE:-none} exceptionPrincipals=${DP_EXC:-none}"
}

# query_agent ID: ask the agent for one model answer (own identity). Sets QRC, Q_DENIED (0/1),
# Q_TEXT (0/1: a model text part appeared), Q_ERR (first error snippet).
query_agent() {
  local id="$1" region
  region="${id#*/locations/}"; region="${region%%/*}"
  export LZV_URL="https://${region}-aiplatform.googleapis.com/v1/${id}:streamQuery?alt=sse"
  export LZV_BODY='{"class_method":"async_stream_query","input":{"user_id":"lzv-t18","message":"Reply with one short sentence: hello."}}'
  run_capture_sh 'out="$(printf "Authorization: Bearer %s\n" "$(gcloud auth print-access-token)" | curl -sS -N --max-time 180 -H @- -H "Content-Type: application/json" -X POST "$LZV_URL" -d "$LZV_BODY" -w "\nHTTP %{http_code}\n" 2>&1)"; printf "%s\n" "$out"; case "$out" in *HTTP\ 200) exit 0 ;; esac; exit 1'
  QRC="$LZV_LAST_RC"
  Q_DENIED=0; Q_TEXT=0; Q_ERR=""
  grep -q 'PERMISSION_DENIED' "$LZV_LAST_OUT" && Q_DENIED=1
  if sed 's/^data: *//' "$LZV_LAST_OUT" | jq -R 'fromjson? | .. | objects | select(has("text")) | .text | select(type == "string" and length > 0)' 2>/dev/null | grep -q .; then
    Q_TEXT=1
  fi
  Q_ERR="$(grep -m1 -o 'PERMISSION_DENIED.\{0,160\}' "$LZV_LAST_OUT" | tr -d '\n' | cut -c1-200)"
  note "http_rc=$QRC permission_denied=$Q_DENIED model_text=$Q_TEXT err=${Q_ERR:-none}"
}

# answered: 0 if the last query produced a model answer without PERMISSION_DENIED.
answered() { [[ "$QRC" == 0 && "$Q_TEXT" == 1 && "$Q_DENIED" == 0 ]]; }

deny_policy_state
case "$STAGE" in
pre)
  [[ "$DP_N" == 0 ]] || guard_abort "stage pre needs enable_dc1_deny=false (policy $POLICY_ID exists)"
  query_agent "$AID_B"; B_OK=0; answered && B_OK=1
  query_agent "$AID_A"; A_OK=0; answered && A_OK=1
  note "PRINCIPALS for terraform.tfvars: dc1_approved_agent_principals = [\"${PRIN_A}\"]  (non-approved agent B: ${PRIN_B})"
  if [[ "$B_OK" == 1 && "$A_OK" == 1 ]]; then
    write_stage PASS "pre: non-approved agent B answered=1, approved agent A answered=1"
  else
    write_stage INCONCLUSIVE "pre: baseline failed (B answered=$B_OK, A answered=$A_OK); the deny effect cannot be attributed"
  fi
  ;;
post)
  [[ "$DP_N" == 1 ]] || guard_abort "stage post needs the deny policy $POLICY_ID (enable_dc1_deny=true applied)"
  [[ -n "$DP_CREATE" ]] || guard_abort "cannot read deny policy createTime"
  AGE=$(( $(date -u +%s) - DP_CREATE ))
  (( AGE >= 600 )) || guard_abort "deny policy is only ${AGE}s old; wait until 10 minutes have passed since createTime"
  [[ -n "$PRIN_A" && "$DP_EXC" == *"$PRIN_A"* ]] || guard_abort "agent A principal is not in the policy exceptionPrincipals"
  [[ -z "$PRIN_B" || "$DP_EXC" != *"$PRIN_B"* ]] || guard_abort "agent B principal must not be an exception"

  query_agent "$AID_B"
  if [[ "$Q_DENIED" == 1 ]]; then
    VB=PASS; OB="agent B refused with PERMISSION_DENIED"; WB=""
  elif answered; then
    VB=FAIL; OB="agent B still answered"; WB="finding: non-approved agent B answered after the deny policy (10+ min); the deny policy did not stop its model call"
  else
    VB=INCONCLUSIVE; OB="agent B query failed without PERMISSION_DENIED"; WB="agent B query failed (http_rc=$QRC) without the PERMISSION_DENIED signature"
  fi
  query_agent "$AID_A"
  if answered; then
    VA=PASS; OA="approved agent A answered"; WA=""
  elif [[ "$Q_DENIED" == 1 ]]; then
    VA=FAIL; OA="approved agent A refused with PERMISSION_DENIED"; WA="finding: the exception principal did not exempt approved agent A"
  else
    VA=INCONCLUSIVE; OA="agent A query failed"; WA="agent A query failed (http_rc=$QRC) without PERMISSION_DENIED"
  fi
  write_stage "$(verdict_merge "$VB" "$VA")" "post: $OB; $OA"

  sp="$(read_stage pre)"; reasons=""
  if [[ "$sp" == MISSING ]]; then sp=INCONCLUSIVE; reasons+="stage pre missing; "; fi
  [[ "$sp" == PASS ]] || reasons+="stage pre: $sp ($(jq -r '.note // empty' "$LZV_DIR/stages/pre.json" 2>/dev/null)); "
  [[ -z "$WB" ]] || reasons+="$WB; "
  [[ -z "$WA" ]] || reasons+="$WA; "
  final="$(verdict_merge "$sp" "$VB" "$VA")"
  [[ "$sp" == PASS ]] || final=INCONCLUSIVE   # without a working baseline the claim is not tested
  pnote="$(jq -r '.note // "pre not run"' "$LZV_DIR/stages/pre.json" 2>/dev/null || echo "pre not run")"
  write_result "$final" Enforced "${pnote}; post: ${OB}; ${OA}; policy listed=1, age=${AGE}s" "$reasons"
  ;;
esac
