#!/usr/bin/env bash
# T36 (v2 D): organization policy staging and inheritance. Custom constraint custom.lzvOrgTestBucketLabel
# on storage.googleapis.com/Bucket (CREATE, ALLOW when the label lzv-org-test is present, so an unlabeled
# bucket is denied). The human applies each org-level change alone (infra t36_mode); this script only
# creates and deletes its own test buckets and reads policy and logs.
# Stages: dryrun | enforce. The result is written by `enforce`.
#   dryrun : org policy has dry_run_spec only (t36_mode=dryrun), 15 min after apply. Unlabeled bucket
#            create in an inheriting project succeeds; audit entry dryRunResult=DENIED, liveResult=ALLOWED
#            appears in cloudaudit.googleapis.com/policy (poll up to 30 min, else INCONCLUSIVE).
#   enforce: org policy has spec (t36_mode=enforce), 15 min after apply. Unlabeled create refused in the
#            inheriting project; the same create in the exception project (output v2_t36_exception_project)
#            succeeds.
# Preconditions: T07 policy (gcp.restrictNonCmekServices) off on the folder, otherwise the bucket create is
# refused for another reason. Buckets are EU (gcp.resourceLocations) and deleted by exact name.
# Rollback (human): terraform apply -var t36_mode=off, or the gcloud org-policies delete commands in infra/v2-org.tf.
# shellcheck disable=SC2016,SC2119
set -u
source "$(dirname "$0")/lib.sh"
require_config

STAGE="${1:-}"
case "$STAGE" in dryrun|enforce) ;; *) lzv_die "usage: T36.sh dryrun|enforce" ;; esac

ORG="$(org_id)"
FOLDER="$(folder_id root)"
BP="$(quota_project)"
CONSTRAINT="custom.lzvOrgTestBucketLabel"
LZV_SCOPE="organizations/$ORG"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/resource-manager/docs/organization-policy/dry-run-policy"
  "https://docs.cloud.google.com/resource-manager/docs/organization-policy/understanding-hierarchy"
  "https://docs.cloud.google.com/resource-manager/docs/organization-policy/creating-managing-custom-constraints"
)
header T36 V2-D "Organization-level policy: dry-run staging, inheritance to projects, a scoped exception project" \
  'Dry run: create allowed, audit entry `dryRunResult=DENIED`, `liveResult=ALLOWED` (poll up to 30 min, else INCONCLUSIVE). Enforced: create refused in an inheriting test project' \
  "$STAGE"
note "paired control (enforce stage): the same unlabeled create in the exception project succeeds"
note "ORG-SCOPE test: the org policy is applied and removed by the human (infra t36_mode); this script never applies it"

json_last() { sed -n '/^[[{]/,$p' "$LZV_LAST_OUT"; }

# --- Guards (read-only) ---
# T07 must be off on the folder (as T08's guard).
GOUT="$(gcloud org-policies describe gcp.restrictNonCmekServices --folder="$FOLDER" --format=json --billing-project="$BP" 2>&1 </dev/null)"
GRC=$?
if [[ $GRC -eq 0 ]]; then
  guard_abort "gcp.restrictNonCmekServices is set on the folder (T07 on): run T36 with enable_t07_policy=false"
elif ! grep -Eqi 'NOT_FOUND|not found' <<<"$GOUT"; then
  guard_abort "cannot read gcp.restrictNonCmekServices on the folder (exit $GRC); state unknown"
fi
EXC="$(lzv_tf '.v2_t36_exception_project.value // empty')"
[[ -n "$EXC" ]] || guard_abort "output v2_t36_exception_project is empty: apply with t36_mode=dryrun or enforce"
if [[ "$EXC" == "$(project_id data)" ]]; then INH="$(project_id mcp)"; else INH="$(project_id data)"; fi
[[ "$INH" != "$EXC" ]] || guard_abort "inheriting and exception project are the same"
note "inheriting project: $INH; exception project: $EXC; location: $LZV_REGION"

if [[ "$STAGE" == dryrun ]]; then KEY=dryRunSpec; else KEY=spec; fi
run_capture gcloud org-policies describe "$CONSTRAINT" --organization="$ORG" --format=json --billing-project="$BP"
[[ "$LZV_LAST_RC" == 0 ]] || guard_abort "organization policy $CONSTRAINT not found (apply t36_mode=$STAGE)"
ORGPOL="$(json_last)"
jq -e --arg k "$KEY" '(.[$k].rules // []) | any((.enforce // false) | tostring | ascii_downcase == "true")' <<<"$ORGPOL" >/dev/null \
  || guard_abort "organization policy has no enforce:true in $KEY (wrong t36_mode for stage $STAGE)"
if [[ "$STAGE" == dryrun ]]; then
  jq -e '(.spec.rules // []) | length == 0' <<<"$ORGPOL" >/dev/null || guard_abort "stage dryrun needs a dry-run-only policy, but spec has rules (live enforcement is already on)"
fi
run_capture gcloud org-policies describe "$CONSTRAINT" --project="$EXC" --format=json --billing-project="$BP"
[[ "$LZV_LAST_RC" == 0 ]] || guard_abort "exception policy on project $EXC not found"
# Fixed 2026-10-27 (run-6 dryrun aborted here): `.enforce // true` turns false into true in jq.
jq -e --arg k "$KEY" '(.[$k].rules // []) | any(has("enforce") and (.enforce | tostring | ascii_downcase) == "false")' <<<"$(json_last)" >/dev/null \
  || guard_abort "exception project policy has no enforce:false in $KEY"
UPD="$(jq -r --arg k "$KEY" '.[$k].updateTime // empty' <<<"$ORGPOL" | sed -E 's/\.[0-9]+Z$/Z/')"
if [[ -n "$UPD" ]]; then
  AGE=$(( $(date -u +%s) - $(jq -rn --arg t "$UPD" '$t | fromdateiso8601') ))
  (( AGE >= 900 )) || guard_abort "org policy $KEY is only ${AGE}s old; wait 15 minutes after the apply"
  note "org policy $KEY age ${AGE}s"
else
  note "WARNING: no updateTime in org policy $KEY; 15 minute wait not checked"
fi

# --- Helpers ---
# mk_cleanup BUCKET PROJECT: register BEFORE creating the bucket (deleted by exact name, no --quiet).
mk_cleanup() {
  cleanup_trap "if gcloud storage buckets describe gs://$1 --project=$2 >/dev/null 2>&1; then gcloud storage buckets delete gs://$1; fi; if gcloud storage buckets describe gs://$1 --project=$2 >/dev/null 2>&1; then echo 'CLEANUP CHECK: bucket $1 still exists'; else echo 'CLEANUP CHECK: bucket $1 gone'; fi"
}
# create_unlabeled BUCKET PROJECT (no labels; EU location)
create_unlabeled() { run_capture gcloud storage buckets create "gs://$1" --location="$LZV_REGION" --project="$2"; }
# delete_bucket BUCKET: explicit delete by exact name, then a describe check
delete_bucket() {
  run_capture gcloud storage buckets delete "gs://$1"
  if gcloud storage buckets describe "gs://$1" >/dev/null 2>&1 </dev/null; then note "bucket $1 STILL EXISTS after delete"; else note "bucket $1 deleted"; fi
}

case "$STAGE" in
dryrun)
  BUCKET="$(lzv_name t36)"
  mk_cleanup "$BUCKET" "$INH"
  START="$(lzv_ts)"
  create_unlabeled "$BUCKET" "$INH"
  if [[ "$LZV_LAST_RC" != 0 ]]; then
    if last_output_matches "$CONSTRAINT"; then
      write_stage FAIL "dryrun: create refused although only the dry run is set ($CONSTRAINT named)"
    else
      write_stage INCONCLUSIVE "dryrun: create failed (exit $LZV_LAST_RC) without naming $CONSTRAINT"
    fi
    exit 0
  fi
  note "unlabeled create in $INH succeeded (dry run does not block)"
  delete_bucket "$BUCKET"
  FOUND=0
  LOGF="log_id(\"cloudaudit.googleapis.com/policy\") AND protoPayload.metadata.dryRunResult=\"DENIED\" AND timestamp>=\"$START\""
  for _ in $(seq 1 15); do   # up to 30 minutes, every 2 minutes
    run_capture gcloud logging read "$LOGF" --project="$INH" --limit=20 --format=json
    if json_last | jq -e --arg b "$BUCKET" --arg c "lzvOrgTestBucketLabel" \
        '[.[]? | select((tojson | contains($b)) and (tojson | contains($c)))] | length > 0' >/dev/null 2>&1; then
      FOUND=1; break
    fi
    sleep 120
  done
  if [[ "$FOUND" == 1 ]]; then
    LIVE="$(json_last | jq -r --arg b "$BUCKET" '[.[]? | select(tojson | contains($b)) | .protoPayload.metadata.liveResult] | unique | join(",")')"
    if [[ "$LIVE" == *ALLOWED* ]]; then
      write_stage PASS "dryrun: create allowed; audit entry dryRunResult=DENIED liveResult=$LIVE for $BUCKET in $INH"
    else
      write_stage FAIL "dryrun: audit entry has dryRunResult=DENIED but liveResult='$LIVE' (expected ALLOWED)"
    fi
  else
    write_stage INCONCLUSIVE "dryrun: create allowed, but no dryRunResult=DENIED audit entry for $BUCKET within 30 minutes"
  fi
  ;;
enforce)
  # Attempt: unlabeled create in the inheriting project
  B1="$(lzv_name t36)"; mk_cleanup "$B1" "$INH"
  create_unlabeled "$B1" "$INH"
  expect_denied "$CONSTRAINT"
  V1="$LZV_VERDICT"; R1="$LZV_REASON"
  OBS1="inheriting project: create exit $LZV_LAST_RC ($(grep -Eo 'customConstraints/[A-Za-z.]+|Operation denied[^.]{0,80}' "$LZV_LAST_OUT" | head -1))"
  if gcloud storage buckets describe "gs://$B1" >/dev/null 2>&1 </dev/null; then
    note "bucket $B1 exists in $INH after the attempt"
    [[ "$V1" == PASS ]] && { V1=FAIL; R1="create reported denied but the bucket exists"; }
  fi
  # Paired control: same create in the exception project
  B2="$(lzv_name t36)"; mk_cleanup "$B2" "$EXC"
  create_unlabeled "$B2" "$EXC"
  expect_success
  V2="$LZV_VERDICT"; R2="$LZV_REASON"
  OBS2="exception project: create exit $LZV_LAST_RC"
  [[ "$V2" == PASS ]] && delete_bucket "$B2"
  # A refusal of the control for another reason makes the attempt unattributable
  if [[ "$V2" != PASS && "$V1" == PASS ]]; then V1=INCONCLUSIVE; R1="paired control (exception project) did not succeed: $R2"; fi
  write_stage "$V1" "enforce: $OBS1; $OBS2"
  DV="$(read_stage dryrun)"
  reasons=""
  if [[ "$DV" == MISSING ]]; then DV=INCONCLUSIVE; reasons+="stage dryrun missing; "; fi
  [[ "$DV" == PASS ]] || reasons+="stage dryrun: $DV ($(jq -r '.note // empty' "$LZV_DIR/stages/dryrun.json" 2>/dev/null)); "
  [[ "$V1" == PASS ]] || reasons+="enforce: $R1; "
  [[ "$V2" == PASS ]] || reasons+="control: $R2; "
  FINAL="$(verdict_merge "$DV" "$V1" "$V2")"
  pnote="$(jq -r '.note // "dryrun not run"' "$LZV_DIR/stages/dryrun.json" 2>/dev/null || echo "dryrun not run")"
  write_result "$FINAL" Enforced "${pnote}; ${OBS1}; ${OBS2}" "$reasons"
  ;;
esac
