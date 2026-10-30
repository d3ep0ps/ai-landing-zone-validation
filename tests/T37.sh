#!/usr/bin/env bash
# T37 (v2 D): IAM deny policy attached to the test FOLDER (fldr-lz-validation) denying
# aiplatform.googleapis.com/endpoints.predict to every agent identity in the organization trust domain
# (principalSet://agents.global.org-ORG_ID.system.id.goog/*), exception: agent A. The project deny policy
# (T18, enable_dc1_deny) is removed in the same apply. Single stage; read-only for cloud state (the human
# applies infra enable_v2_folder_deny=true; this script only lists/gets policies and queries agents).
# Run order: tests/RUN-ORDER-run6.md stage 2-6b, at least 10 minutes after the folder policy createTime.
# Needs agents A and B (infra/agents). Pattern: tests/T18.sh post.
# shellcheck disable=SC2016
set -u
source "$(dirname "$0")/lib.sh"
require_config

FOLDER="$(folder_id root)"
ORG="$(org_id)"
RT="$(project_id runtime)"
LZV_SCOPE="folders/$FOLDER"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/iam/docs/deny-access"
  "https://docs.cloud.google.com/iam/docs/principal-identifiers"
  "https://docs.cloud.google.com/iam/docs/deny-permissions-support"
)
header T37 V2-D "Folder-attached IAM deny policy for all agent identities of the organization trust domain, exception for one approved agent" \
  'Agent B refused (`PERMISSION_DENIED`, deny-policy text); agent A answered'
note "no resources are created by this script (agents and the deny policy are Terraform-managed); no cleanup_trap registered"
note "limitation: whether a folder-attached deny catches an org-trust-domain principal is the thing under test (UNVERIFIED); cause is attributed by the paired control (agent A answers) and the listed policy"

FOLDER_POLICY="lzv-v2-deny-agent-predict"
PROJECT_POLICY="lzv-dc1-deny-agent-predict"
FAP="cloudresourcemanager.googleapis.com/folders/$FOLDER"
PAP="cloudresourcemanager.googleapis.com/projects/$RT"
BP="$(quota_project)"

AID_A="$(agents_tf '.agent_a.value.id' 2>/dev/null)" || AID_A=""
AID_B="$(agents_tf '.agent_b.value.id' 2>/dev/null)" || AID_B=""
[[ -n "$AID_A" && -n "$AID_B" ]] || guard_abort "deploy agents A and B first (deploy_agent_a=true, deploy_agent_b=true)"
PRIN_A="$(agents_tf '.agent_a.value.identity' 2>/dev/null)" || PRIN_A=""
PRIN_B="$(agents_tf '.agent_b.value.identity' 2>/dev/null)" || PRIN_B=""
note "agent A id: $AID_A"
note "agent B id: $AID_B"
note "agent A principal: $PRIN_A"
note "agent B principal: $PRIN_B"
TRUST="principalSet://agents.global.org-${ORG}.system.id.goog/*"
[[ "$PRIN_B" == principal://agents.global.org-"${ORG}".system.id.goog/* ]] \
  || note "WARNING: agent B principal is not in the org trust domain agents.global.org-<ORG_ID>.system.id.goog; the folder policy may not match it"

# --- Guards: folder deny present and aged; project deny absent ---
run_capture gcloud iam policies list --attachment-point="$FAP" --kind=denypolicies --format=json --billing-project="$BP"
[[ "$LZV_LAST_RC" == 0 ]] || guard_abort "cannot list folder deny policies (exit $LZV_LAST_RC)"
J="$(sed -n '/^[[{]/,$p' "$LZV_LAST_OUT")"; [[ -n "$J" ]] || J='{}'
SEL='(if type == "array" then . else (.policies // []) end) | [.[] | select((.name | split("/") | last) == $id)]'
[[ "$(jq --arg id "$FOLDER_POLICY" "$SEL | length" <<<"$J")" == 1 ]] || guard_abort "folder deny policy $FOLDER_POLICY not found (enable_v2_folder_deny=true applied?)"
CREATE="$(jq -r --arg id "$FOLDER_POLICY" "$SEL | .[0].createTime // empty | if . == \"\" then \"\" else (sub(\"\\\\.[0-9]+Z\$\"; \"Z\") | fromdateiso8601 | tostring) end" <<<"$J")"
[[ -n "$CREATE" ]] || guard_abort "cannot read folder deny policy createTime"
AGE=$(( $(date -u +%s) - CREATE ))
(( AGE >= 600 )) || guard_abort "folder deny policy is only ${AGE}s old; wait until 10 minutes have passed since createTime"

run_capture gcloud iam policies get "$FOLDER_POLICY" --attachment-point="$FAP" --kind=denypolicies --format=json --billing-project="$BP"
[[ "$LZV_LAST_RC" == 0 ]] || guard_abort "cannot read folder deny policy $FOLDER_POLICY"
PJ="$(sed -n '/^[[{]/,$p' "$LZV_LAST_OUT")"
jq -e --arg t "$TRUST" '[.rules[]?.denyRule.deniedPrincipals[]?] | index($t) != null' <<<"$PJ" >/dev/null || guard_abort "folder policy does not deny $TRUST"
jq -e '[.rules[]?.denyRule.deniedPermissions[]?] | index("aiplatform.googleapis.com/endpoints.predict") != null' <<<"$PJ" >/dev/null || guard_abort "folder policy does not deny endpoints.predict"
EXC="$(jq -r '[.rules[]?.denyRule.exceptionPrincipals[]?] | join(", ")' <<<"$PJ")"
[[ -n "$PRIN_A" && "$EXC" == *"$PRIN_A"* ]] || guard_abort "agent A principal is not in the folder policy exceptionPrincipals"
[[ -z "$PRIN_B" || "$EXC" != *"$PRIN_B"* ]] || guard_abort "agent B principal must not be an exception"
note "folder deny policy $FOLDER_POLICY present, age ${AGE}s, exceptionPrincipals=$EXC"

run_capture gcloud iam policies list --attachment-point="$PAP" --kind=denypolicies --format=json --billing-project="$BP"
[[ "$LZV_LAST_RC" == 0 ]] || guard_abort "cannot list project deny policies (exit $LZV_LAST_RC)"
PJL="$(sed -n '/^[[{]/,$p' "$LZV_LAST_OUT")"; [[ -n "$PJL" ]] || PJL='{}'
[[ "$(jq --arg id "$PROJECT_POLICY" "$SEL | length" <<<"$PJL")" == 0 ]] || guard_abort "project deny policy $PROJECT_POLICY still exists: apply enable_dc1_deny=false so the folder policy is the only cause"
note "project deny policy $PROJECT_POLICY absent"

# query_agent ID: one model answer under the agent's own identity (as T18). Sets QRC, Q_DENIED, Q_TEXT, Q_ERR.
query_agent() {
  local id="$1" region
  region="${id#*/locations/}"; region="${region%%/*}"
  export LZV_URL="https://${region}-aiplatform.googleapis.com/v1/${id}:streamQuery?alt=sse"
  export LZV_BODY='{"class_method":"async_stream_query","input":{"user_id":"lzv-t37","message":"Reply with one short sentence: hello."}}'
  run_capture_sh 'out="$(printf "Authorization: Bearer %s\n" "$(gcloud auth print-access-token)" | curl -sS -N --max-time 180 -H @- -H "Content-Type: application/json" -X POST "$LZV_URL" -d "$LZV_BODY" -w "\nHTTP %{http_code}\n" 2>&1)"; printf "%s\n" "$out"; case "$out" in *HTTP\ 200) exit 0 ;; esac; exit 1'
  QRC="$LZV_LAST_RC"
  Q_DENIED=0; Q_TEXT=0; Q_ERR=""
  grep -q 'PERMISSION_DENIED' "$LZV_LAST_OUT" && Q_DENIED=1
  if sed 's/^data: *//' "$LZV_LAST_OUT" | jq -R 'fromjson? | .. | objects | select(has("text")) | .text | select(type == "string" and length > 0)' 2>/dev/null | grep -q .; then
    Q_TEXT=1
  fi
  Q_ERR="$(grep -m1 -o 'PERMISSION_DENIED.\{0,300\}' "$LZV_LAST_OUT" | tr -d '\n' | cut -c1-320)"
  note "http_rc=$QRC permission_denied=$Q_DENIED model_text=$Q_TEXT err=${Q_ERR:-none}"
}
answered() { [[ "$QRC" == 0 && "$Q_TEXT" == 1 && "$Q_DENIED" == 0 ]]; }

# --- Attempt: agent B (not an exception) ---
query_agent "$AID_B"
DPT=0; grep -qi 'deny policy' "$LZV_LAST_OUT" && DPT=1
if [[ "$Q_DENIED" == 1 ]]; then
  VB=PASS; OB="agent B refused with PERMISSION_DENIED (deny-policy wording present: $DPT; text: ${Q_ERR:0:200})"; WB=""
  [[ "$DPT" == 1 ]] || note "PERMISSION_DENIED text does not name a deny policy (as T18); attribution rests on the paired control"
elif answered; then
  VB=FAIL; OB="agent B still answered"; WB="finding: non-approved agent B answered with the folder deny policy 10+ minutes old; the folder-attached deny did not stop its model call"
else
  VB=INCONCLUSIVE; OB="agent B query failed without PERMISSION_DENIED"; WB="agent B query failed (http_rc=$QRC) without the PERMISSION_DENIED signature"
fi

# --- Paired control: agent A (exception) ---
query_agent "$AID_A"
if answered; then
  VA=PASS; OA="approved agent A answered"; WA=""
elif [[ "$Q_DENIED" == 1 ]]; then
  VA=FAIL; OA="approved agent A refused with PERMISSION_DENIED"; WA="finding: the exception principal did not exempt approved agent A"
else
  VA=INCONCLUSIVE; OA="agent A query failed"; WA="agent A query failed (http_rc=$QRC) without PERMISSION_DENIED"
fi

FINAL="$(verdict_merge "$VB" "$VA")"
REASONS=""; [[ -z "$WB" ]] || REASONS+="$WB; "; [[ -z "$WA" ]] || REASONS+="$WA; "
[[ "$FINAL" == PASS ]] && REASONS=""
write_result "$FINAL" Enforced "${OB}; ${OA}; folder policy listed, age=${AGE}s, project policy absent" "$REASONS"
