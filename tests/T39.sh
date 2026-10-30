#!/usr/bin/env bash
# T39 and T39b (v2 E), one script with two stages because lib.sh accepts test IDs only as ^T[0-9]{2}R?$
# ("T39b" does not match and lib.sh is not edited). Stages: split | egress. Evidence: evidence/T39/RUN_ID/
# (stages/split.json = T39, stages/egress.json = T39b; result.json is written when both stages exist and
# carries both expected results and both verdicts in `actual`).
#   split  (T39) : full `terraform plan -lock=false -detailed-exitcode` in infra-split/inside (in-perimeter
#                  quota project = data project) and infra-split/outside (outside quota project = seed), with
#                  the perimeter enforced. PASS: both exit 0 or 2 and no enforced VPC-SC violation naming
#                  either quota project in the window. Control: T22 single-stack failure (existing evidence).
#   egress (T39b): full plan of the single stack (infra/) with the outside quota project (seed) and the
#                  egress rule vpc_sc_pipeline_egress on. Control: the same read as another identity
#                  (T39B_OTHER_SA, a service account the operator can impersonate and that is not in the
#                  egress rule) is refused.
# Read-only: terraform plans (never apply; -lock=false so the human's state lock is not held) and gcloud reads.
# The human runs `terraform init` in infra-split/inside and infra-split/outside first.
# Run order: tests/RUN-ORDER-run6.md stage 2-4 (after the egress rule and the enforced perimeter propagate).
# shellcheck disable=SC2016,SC2119
set -u
source "$(dirname "$0")/lib.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in split|egress) ;; *) lzv_die "usage: T39.sh split|egress  (egress = T39b)" ;; esac

FOLDER="$(folder_id root)"
LZV_SCOPE="folders/$FOLDER"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/vpc-service-controls/docs/ingress-egress-rules"
  "https://docs.cloud.google.com/vpc-service-controls/docs/audit-logging"
  "https://docs.cloud.google.com/docs/quotas/quota-project"
)
E_T39='Both full plans exit 0 or 2; no VPC-SC violation names either quota project'
E_T39B='Full plan succeeds'
if [[ "$STAGE" == split ]]; then
  header T39 V2-E "Two Terraform roots split along the perimeter boundary (inside: in-perimeter quota project; outside: outside quota project); control: T22 single-stack failure" "$E_T39" "$STAGE"
else
  header T39 V2-E "T39b: single stack, quota project outside the perimeter, egress rule for the pipeline identity; control: same call by another identity refused" "$E_T39B" "$STAGE"
fi
note "this script is T39 (stage split) and T39b (stage egress); lib.sh ID pattern does not allow 'T39b'"
note "no resources are created; no cleanup_trap registered"

json_last() { sed -n '/^[[{]/,$p' "$LZV_LAST_OUT"; }
VPCSC_SIG='VPC Service Controls|VPC_SERVICE_CONTROLS|vpcServiceControlsUniqueIdentifier|SECURITY_POLICY_VIOLATED|Request is prohibited by organization'

SEED="$(quota_project)"
DATA="$(project_id data)"
RUNTIME="$(project_id runtime)"
MCP="$(project_id mcp)"
NUM_DATA="$(project_number data)"
NUM_SEED="$(gcloud projects describe "$SEED" --format='value(projectNumber)' </dev/null 2>/dev/null)"
[[ -n "$NUM_SEED" ]] || guard_abort "cannot read the seed project number"

# --- Guard: perimeter enforced (status) ---
run_capture gcloud access-context-manager policies list --organization="$(org_id)" --format=json
POLNAME="$(json_last | jq -r --arg g "folders/$FOLDER" '[.[] | select((.scopes // []) | index($g))][0].name // empty' | sed 's#^accessPolicies/##')"
[[ -n "$POLNAME" ]] || guard_abort "no access policy scoped to the test folder"
run_capture gcloud access-context-manager perimeters describe lzv_ai --policy="$POLNAME" --format=json
PERIM="$(json_last)"
NSTAT="$(jq -r '(.status.resources // []) | length' <<<"$PERIM")"
[[ "$NSTAT" =~ ^[0-9]+$ && "$NSTAT" -gt 0 ]] || guard_abort "the perimeter is not enforced (status has no resources); wait 15 min after vpc_sc_enforced=true"
jq -e --arg p "projects/$NUM_DATA" '[(.status.resources // [])[] | select(. == $p)] | length == 1' <<<"$PERIM" >/dev/null || guard_abort "the data project is not in the enforced perimeter"
note "perimeter lzv_ai enforced: status resources=$NSTAT"

START="$(lzv_ts)"

# count_violations QUOTA_ID QUOTA_NUMBER -> enforced (non dry-run) VPC-SC entries since START whose
# egress violation target is that project (logs of the three in-perimeter projects).
count_violations() {
  local pid="$1" pnum="$2" filter p total=0 n
  filter='log_id("cloudaudit.googleapis.com/policy") severity=ERROR protoPayload.metadata."@type"="type.googleapis.com/google.cloud.audit.VpcServiceControlAuditMetadata" NOT protoPayload.metadata.dryRun=true'
  filter+=" timestamp>=\"$START\""
  for p in "$DATA" "$RUNTIME" "$MCP"; do
    run_capture gcloud logging read "$filter" --project="$p" --format=json >&2
    n="$(json_last | jq -r --arg a "$pid" --arg b "$pnum" \
      '[.[]? | select([.protoPayload.metadata.egressViolations[]?.targetResource // "" | (contains($a) or contains($b))] | any)] | length' 2>/dev/null)"
    total=$(( total + ${n:-0} ))
  done
  echo "$total"
}

# plan_root DIR QUOTA_PROJECT: full plan, read-only. Sets PLAN_RC and PLAN_OUT (copy of the plan output).
plan_root() {
  local dir="$1" qp="$2"
  # providers set billing_project = var.quota_project, and tfvars outrank TF_VAR_*: pass -var (as T22).
  run_capture env GOOGLE_BILLING_PROJECT="$qp" USER_PROJECT_OVERRIDE=true \
    terraform -chdir="$dir" plan -input=false -lock=false -detailed-exitcode -var "quota_project=$qp"
  PLAN_RC="$LZV_LAST_RC"
  PLAN_OUT="$LZV_DIR/.plan-output-$(basename "$dir")"
  cp "$LZV_LAST_OUT" "$PLAN_OUT"
}

# classify_plan RC OUTFILE -> prints PASS | FAIL | INCONCLUSIVE
classify_plan() {
  if [[ "$1" == 0 || "$1" == 2 ]]; then echo PASS
  elif grep -Eq "$VPCSC_SIG" "$2"; then echo FAIL
  else echo INCONCLUSIVE; fi
}

case "$STAGE" in
split)
  IN_DIR="$LZV_ROOT/infra-split/inside"; OUT_DIR="$LZV_ROOT/infra-split/outside"
  for d in "$IN_DIR" "$OUT_DIR"; do
    [[ -d "$d/.terraform" ]] || guard_abort "terraform init not run in ${d#"$LZV_ROOT"/}"
  done
  note "inside quota project: $DATA (in perimeter); outside quota project: $SEED (outside)"
  plan_root "$IN_DIR" "$DATA";  RC_IN="$PLAN_RC";  V_IN="$(classify_plan "$RC_IN" "$PLAN_OUT")"
  plan_root "$OUT_DIR" "$SEED"; RC_OUT="$PLAN_RC"; V_OUT="$(classify_plan "$RC_OUT" "$PLAN_OUT")"
  note "plans: inside exit $RC_IN ($V_IN), outside exit $RC_OUT ($V_OUT)"
  sleep 120   # violation entries lag
  N_IN="$(count_violations "$DATA" "$NUM_DATA")"
  N_OUT="$(count_violations "$SEED" "$NUM_SEED")"
  note "enforced egress violations since $START: naming inside quota project=$N_IN, naming outside quota project=$N_OUT"
  T22F="$LZV_ROOT/evidence/T22/$RUN_ID/stages/enforced.json"
  if [[ -f "$T22F" ]]; then note "control T22 enforced stage in this run: $(jq -r '.verdict + ": " + (.note // "")' "$T22F" | cut -c1-200)"; else note "control T22 single-stack evidence for $RUN_ID not found (existing evidence of the F9/T22 failure is the reference)"; fi
  V="$(verdict_merge "$V_IN" "$V_OUT")"; WHY="inside plan exit $RC_IN, outside plan exit $RC_OUT; enforced violations since $START naming inside quota project=$N_IN, outside=$N_OUT"
  [[ "$N_IN" -eq 0 && "$N_OUT" -eq 0 ]] || V=FAIL
  write_stage "$V" "T39 split: $WHY"
  ;;
egress)
  # Guard: the egress rule is in the enforced spec (status) for the seed project.
  jq -e --arg p "projects/$NUM_SEED" '[(.status.egressPolicies // [])[] | (.egressTo.resources // [])[] | select(. == $p)] | length > 0' <<<"$PERIM" >/dev/null \
    || guard_abort "enforced perimeter has no egress policy for projects/<seed number> (set vpc_sc_pipeline_egress and vpc_sc_enforced=true; wait 15 min)"
  note "egress policy for the seed project present in the enforced perimeter; services: $(jq -r '[(.status.egressPolicies // [])[] | (.egressTo.operations // [])[] | .serviceName] | unique | join(",")' <<<"$PERIM")"
  [[ -d "$LZV_ROOT/infra/.terraform" ]] || guard_abort "terraform is not initialised in infra/"
  note "single stack, quota project outside the perimeter: $SEED"
  plan_root "$LZV_ROOT/infra" "$SEED"; RC_P="$PLAN_RC"; V_P="$(classify_plan "$RC_P" "$PLAN_OUT")"
  note "single-stack full plan exit $RC_P ($V_P)"
  sleep 120   # violation entries lag
  N_S="$(count_violations "$SEED" "$NUM_SEED")"
  note "enforced egress violations since $START naming the seed project: $N_S"

  # Paired control: another identity, same call, refused.
  V_C=INCONCLUSIVE; WHY_C=""
  OTHER="${T39B_OTHER_SA:-}"
  if [[ -z "$OTHER" ]]; then
    WHY_C="paired control not run: set T39B_OTHER_SA to a service account the operator can impersonate"
  elif jq -e --arg o "$OTHER" '[(.status.egressPolicies // [])[] | (.egressFrom.identities // [])[] | select(. == ("serviceAccount:" + $o))] | length > 0' <<<"$PERIM" >/dev/null; then
    WHY_C="paired control invalid: T39B_OTHER_SA is listed in the egress rule"
  elif ! jq -e --arg o "$OTHER" '[(.status.ingressPolicies // [])[] | (.ingressFrom.identities // [])[] | select(. == ("serviceAccount:" + $o))] | length > 0' <<<"$PERIM" >/dev/null; then
    # Added 2026-10-27 before run-6: without ingress the control is refused at ingress, which says nothing
    # about the egress rule (set vpc_sc_operator_ingress_extra_identities).
    WHY_C="paired control invalid: T39B_OTHER_SA is not in the operator ingress rule (refusal would be an ingress refusal)"
  else
    run_capture gcloud storage buckets list --project="$DATA" --billing-project="$SEED" --impersonate-service-account="$OTHER" --format='value(name)'
    if expect_denied "$VPCSC_SIG"; then
      sleep 60
      run_capture gcloud logging read "log_id(\"cloudaudit.googleapis.com/policy\") severity=ERROR timestamp>=\"$START\" NOT protoPayload.metadata.dryRun=true" --project="$DATA" --limit=50 --format=json
      # Control passes only if the refusal is an egress violation naming the seed project (not an ingress one).
      N_CE="$(sed -n '/^[[{]/,$p' "$LZV_LAST_OUT" | jq -r --arg o "$OTHER" --arg a "$SEED" --arg b "${NUM_SEED:-__none__}" \
        '[.[]? | select((.protoPayload.authenticationInfo.principalEmail // "") == $o) | select([.protoPayload.metadata.egressViolations[]?.targetResource // "" | (contains($a) or contains($b))] | any)] | length' 2>/dev/null)"
      if [[ "${N_CE:-0}" -gt 0 ]]; then V_C=PASS; note "control: $N_CE enforced egress violation(s) for $OTHER naming the seed project"
      else WHY_C="control refused by VPC-SC, but no egress violation for the control identity naming the seed project (refusal may be by another rule)"; fi
    else
      V_C="$LZV_VERDICT"; WHY_C="control by another identity: $LZV_REASON"
    fi
  fi
  V="$V_P"; WHY="single-stack full plan exit $RC_P; enforced violations naming seed project=$N_S; ${WHY_C:-control by another identity refused}"
  [[ "$V_P" == PASS && "$N_S" -gt 0 ]] && V=FAIL
  [[ "$V" == PASS ]] && V="$(verdict_merge PASS "$V_C")"
  write_stage "$V" "T39b egress: $WHY"
  ;;
esac

# --- Result once both stages exist ---
SV="$(read_stage split)"; EV="$(read_stage egress)"
if [[ "$SV" == MISSING || "$EV" == MISSING ]]; then
  note "result.json not written yet: stage split=$SV, egress=$EV (the other stage must run with the same RUN_ID)"
  exit 0
fi
NS="$(jq -r '.note' "$LZV_DIR/stages/split.json")"; NE="$(jq -r '.note' "$LZV_DIR/stages/egress.json")"
LZV_EXPECTED="T39: $E_T39 | T39b: $E_T39B"
LZV_CONTROL="T39: T22 single-stack failure | T39b: same call by another identity refused"
FINAL="$(verdict_merge "$SV" "$EV")"
REASONS=""
[[ "$SV" == PASS ]] || REASONS+="T39 split: $SV ($NS); "
[[ "$EV" == PASS ]] || REASONS+="T39b egress: $EV ($NE); "
write_result "$FINAL" Enforced "T39 split=$SV: $NS | T39b egress=$EV: $NE" "$REASONS"
