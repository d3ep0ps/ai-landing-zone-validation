#!/usr/bin/env bash
# T22 (v1.1, DC2 step 1): tooling quota project inside the perimeter. Stages: dryrun | enforced
# Read-only: terraform plan (never apply, -lock=false so the human's state lock is not held) and gcloud reads.
# shellcheck disable=SC2016,SC2119
set -u
source "$(dirname "$0")/lib.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in dryrun|enforced) ;; *) lzv_die "usage: T22.sh dryrun|enforced" ;; esac

FOLDER="$(folder_id root)"
LZV_SCOPE="folders/$FOLDER"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/docs/quotas/quota-project"
  "https://docs.cloud.google.com/vpc-service-controls/docs/audit-logging"
  "https://raw.githubusercontent.com/hashicorp/terraform-provider-google/main/website/docs/guides/provider_reference.html.markdown"
)

TOOL="$(lzv_tf '.tooling_quota_project.value // empty')"
[[ -n "$TOOL" ]] || lzv_die "tooling_quota_project output is empty: set it (DC2) and apply"
SEED="$(quota_project)"
DATA="$(project_id data)"
RUNTIME="$(project_id runtime)"

header T22 Reach "DC2 (1)" \
  'Run first in dry-run: violation entries for the old quota project, none for the tooling quota project. Enforced: both succeed; no egress violation for the tooling quota project' \
  "$STAGE"

json_last() { sed -n '/^[[{]/,$p' "$LZV_LAST_OUT"; }
VPCSC_SIG='VPC Service Controls|VPC_SERVICE_CONTROLS|vpcServiceControlsUniqueIdentifier|SECURITY_POLICY_VIOLATED'

# Perimeter state guard: dryrun = projects only in spec; enforced = projects in status.
run_capture gcloud access-context-manager policies list --organization="$(org_id)" --format=json
POLNAME="$(json_last | jq -r --arg f "$LZV_SCOPE" '[.[] | select((.scopes // []) | index($f))][0].name // empty' | sed 's#^accessPolicies/##')"
[[ -n "$POLNAME" ]] || lzv_die "no access policy scoped to $LZV_SCOPE"
run_capture gcloud access-context-manager perimeters describe lzv_ai --policy="$POLNAME" --format=json
NSPEC="$(json_last | jq -r '(.spec.resources // []) | length')"
NSTAT="$(json_last | jq -r '(.status.resources // []) | length')"
[[ "$NSPEC" =~ ^[0-9]+$ && "$NSTAT" =~ ^[0-9]+$ ]] || lzv_die "cannot read perimeter state"
note "perimeter lzv_ai: spec resources=$NSPEC, status resources=$NSTAT"
case "$STAGE" in
  dryrun)   [[ "$NSPEC" -gt 0 && "$NSTAT" -eq 0 ]] || lzv_die "stage dryrun needs a dry-run perimeter that includes the projects (vpc_sc_enforced=false)" ;;
  enforced) [[ "$NSTAT" -gt 0 ]] || lzv_die "stage enforced needs an enforced perimeter (vpc_sc_enforced=true); wait 15 min after apply" ;;
esac

NUM_TOOL="$(gcloud projects describe "$TOOL" --format='value(projectNumber)' </dev/null 2>/dev/null)"
NUM_SEED="$(gcloud projects describe "$SEED" --format='value(projectNumber)' </dev/null 2>/dev/null)"

# count_violations MODE(dry|enforced) PROJECT_ID PROJECT_NUMBER -> prints number of VPC-SC entries with an
# egress violation whose targetResource is that project (data and runtime project logs, last 30 min).
# Changed 2026-10-25 after run-4 dryrun: matching anywhere in egress/ingress fields also counted ingress
# entries where the tooling project (data) was only the resource read from outside, and egress sources.
count_violations() {
  local mode="$1" pid="$2" pnum="$3" filter p total=0 n
  filter='log_id("cloudaudit.googleapis.com/policy") severity=ERROR protoPayload.metadata."@type"="type.googleapis.com/google.cloud.audit.VpcServiceControlAuditMetadata"'
  if [[ "$mode" == dry ]]; then filter+=' protoPayload.metadata.dryRun=true'; else filter+=' NOT protoPayload.metadata.dryRun=true'; fi
  for p in "$DATA" "$RUNTIME"; do
    run_capture gcloud logging read "$filter" --project="$p" --freshness=30m --format=json >&2
    n="$(json_last | jq -r --arg a "$pid" --arg b "${pnum:-__none__}" \
      '[.[]? | select([.protoPayload.metadata.egressViolations[]?.targetResource // "" | (contains($a) or contains($b))] | any)] | length' 2>/dev/null)"
    total=$(( total + ${n:-0} ))
  done
  echo "$total"
}

# plan_and_read: terraform plan read-only + gcloud read with the given billing project. Sets PLAN_RC, READ_RC.
plan_and_read() {
  local bp="$1"
  # The providers set billing_project = var.quota_project explicitly, and terraform.tfvars outranks
  # TF_VAR_*, so the quota project is passed with -var (env vars alone would still bill the seed).
  # Fixed 2026-10-25 before the first T22 stage.
  run_capture env GOOGLE_BILLING_PROJECT="$bp" USER_PROJECT_OVERRIDE=true \
    terraform -chdir="$LZV_ROOT/infra" plan -input=false -lock=false -detailed-exitcode -var "quota_project=$bp"
  # Keep a copy: the next run_capture overwrites .last-output (run-5 enforced checked the read output, not the plan).
  PLAN_RC="$LZV_LAST_RC"; PLAN_OUT="$LZV_DIR/.plan-output"; cp "$LZV_LAST_OUT" "$PLAN_OUT"
  run_capture gcloud storage buckets list --project="$DATA" --billing-project="$bp" --format='value(name)'
  READ_RC="$LZV_LAST_RC"
}

case "$STAGE" in
dryrun)
  # Old quota project: the v1 failing call repeated (read only), so dry-run entries for it exist.
  run_capture gcloud storage buckets list --project="$DATA" --billing-project="$SEED" --format='value(name)'
  note "control read with the old quota project: exit $LZV_LAST_RC (dry-run: expected to succeed)"
  plan_and_read "$TOOL"
  sleep 120   # violation entries lag
  OLD="$(count_violations dry "$SEED" "$NUM_SEED")"
  NEW="$(count_violations dry "$TOOL" "$NUM_TOOL")"
  note "dry-run violations in last 30 min: naming old quota project=$OLD, naming tooling quota project=$NEW"
  v=PASS; why="plan exit $PLAN_RC, read exit $READ_RC; dry-run violations old=$OLD tooling=$NEW"
  if [[ "$PLAN_RC" != 0 && "$PLAN_RC" != 2 ]] || [[ "$READ_RC" != 0 ]]; then v=INCONCLUSIVE; why+="; plan or read with the tooling quota project failed"; fi
  [[ "$NEW" -eq 0 ]] || v=FAIL
  [[ "$OLD" -gt 0 ]] || { [[ "$v" == PASS ]] && v=INCONCLUSIVE; why+="; no dry-run entry for the old quota project (no baseline)"; }
  write_stage "$v" "$why"
  ;;
enforced)
  plan_and_read "$TOOL"
  v=PASS; why="plan exit $PLAN_RC, read exit $READ_RC"
  if [[ "$PLAN_RC" != 0 && "$PLAN_RC" != 2 ]]; then
    # run-4-r2 enforced was INCONCLUSIVE because the 403 text is "Request is prohibited by organization's
    # policy. vpcServiceControlsUniqueIdentifier" / SECURITY_POLICY_VIOLATED; signature widened before run-5.
    if grep -Eq "$VPCSC_SIG" "$PLAN_OUT"; then v=FAIL; why+="; plan refused by VPC-SC"; else v=INCONCLUSIVE; why+="; plan failed without a VPC-SC signature"; fi
  fi
  if [[ "$READ_RC" != 0 ]]; then
    if last_output_matches "$VPCSC_SIG"; then v=FAIL; why+="; read refused by VPC-SC"; else
      [[ "$v" == PASS ]] && v=INCONCLUSIVE; why+="; read failed without a VPC-SC signature"; fi
  fi
  sleep 120   # violation entries lag
  NEW="$(count_violations enforced "$TOOL" "$NUM_TOOL")"
  note "enforced egress/ingress violations naming the tooling quota project in last 30 min: $NEW"
  why+="; violations naming tooling quota project=$NEW"
  [[ "$NEW" -eq 0 ]] || v=FAIL
  write_stage "$v" "$why"
  DV="$(read_stage dryrun)"
  reason=""
  [[ "$DV" == PASS ]] || reason+="dryrun stage: $DV; "
  [[ "$v" == PASS ]] || reason+="enforced stage: $why; "
  write_result "$(verdict_merge "$DV" "$v")" Enforced "dryrun stage: $DV; enforced stage: $why" "$reason"
  ;;
esac
