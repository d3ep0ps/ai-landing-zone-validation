#!/usr/bin/env bash
# T13: VPC-SC perimeter denies outside read and cross-perimeter copy. Stages: setup | dryrun | outside-read | copy
# shellcheck disable=SC2016,SC2119
set -u
source "$(dirname "$0")/lib.sh"
require_config

STAGE="${1:-}"
# A retry of a stage is named STAGE-rN (e.g. outside-read-r2); it runs the same logic and is
# recorded as its own stage file, so earlier attempts stay on record.
BASE="${STAGE%-r[0-9]*}"
case "$BASE" in setup|dryrun|outside-read|copy) ;; *) lzv_die "usage: T13.sh setup|dryrun|outside-read|copy (retry: STAGE-rN)" ;; esac

LZV_SCOPE="folders/$(folder_id root)"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/vpc-service-controls/docs/overview"
  "https://docs.cloud.google.com/vpc-service-controls/docs/audit-logging"
  "https://docs.cloud.google.com/vpc-service-controls/docs/troubleshooting"
)
header T13 "Baseline (Reach)" "VPC-SC perimeter (dry-run control first, then enforced)" \
  'Both denied; audit log violation reasons `NO_MATCHING_ACCESS_LEVEL` (a) and regex `RESOURCES?_NOT_IN_SAME_SERVICE_PERIMETER` (b)' \
  "$STAGE"

OBJ="probe.txt"
PROBE_TEXT="lzv-t13-fixture"
DENY_RE='Request violates VPC Service Controls|vpcServiceControlsUniqueIdentifier'
LOG_BASE='log_id("cloudaudit.googleapis.com/policy") severity=ERROR resource.type="audited_resource" protoPayload.metadata."@type"="type.googleapis.com/google.cloud.audit.VpcServiceControlAuditMetadata"'
LOG_ANY=0; LOG_REASONS=""

json_last() { sed -n '/^[[{]/,$p' "$LZV_LAST_OUT"; }

# --- Perimeter state guard ---------------------------------------------------
# $1 = want: dryrun-only | enforced-noingress | enforced-ingress
perimeter_guard() {
  local want="$1" pol nres ning
  run_capture gcloud access-context-manager policies list --organization="$(org_id)" --format=json
  pol="$(json_last | jq -r --arg f "$LZV_SCOPE" '[.[] | select((.scopes // []) | index($f))][0].name // empty' | sed 's#^accessPolicies/##')"
  [[ -n "$pol" ]] || lzv_die "no access policy scoped to $LZV_SCOPE"
  run_capture gcloud access-context-manager perimeters describe lzv_ai --policy="$pol" --format=json
  nres="$(json_last | jq -r '(.status.resources // []) | length')"
  ning="$(json_last | jq -r '(.status.ingressPolicies // []) | length')"
  [[ "$nres" =~ ^[0-9]+$ && "$ning" =~ ^[0-9]+$ ]] || lzv_die "cannot read perimeter state"
  note "perimeter lzv_ai: status resources=$nres, status ingressPolicies=$ning (want $want)"
  case "$want" in
    dryrun-only)        [[ "$nres" -eq 0 ]] || lzv_die "perimeter is enforced (status resources present); stage $STAGE needs dry-run only" ;;
    enforced-noingress) [[ "$nres" -gt 0 && "$ning" -eq 0 ]] || lzv_die "stage $STAGE needs an enforced perimeter with no ingress policy" ;;
    enforced-ingress)   [[ "$nres" -gt 0 && "$ning" -gt 0 ]] || lzv_die "stage $STAGE needs an enforced perimeter with an ingress policy" ;;
  esac
}

# --- Violation log poll ------------------------------------------------------
# log_poll MODE(dry|enforced) UNIQUE_ID REASON_REGEX ; sets LOG_ANY, LOG_REASONS
log_poll() {
  local mode="$1" id="$2" re="$3" try proj filter n reasons
  filter="$LOG_BASE"
  # Enforced entries have no dryRun field; '!=' does not match a missing field (run 1 finding).
  if [[ "$mode" == dry ]]; then filter+=' protoPayload.metadata.dryRun=true'; else filter+=' NOT protoPayload.metadata.dryRun=true'; fi
  [[ -n "$id" ]] && filter+=" protoPayload.metadata.vpcServiceControlsUniqueId=\"$id\""
  LOG_ANY=0; LOG_REASONS=""
  for try in 1 2 3 4 5; do
    for proj in "$(project_id data)" "$(project_id outside)"; do
      run_capture gcloud logging read "$filter" --project="$proj" --freshness=1h --format=json
      n="$(json_last | jq -r 'length' 2>/dev/null)"
      [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] || continue
      LOG_ANY=1
      reasons="$(json_last | jq -r '[.[].protoPayload.metadata.violationReason // empty] | unique | join(",")')"
      LOG_REASONS="$reasons"
      {
        echo "## evidence fields (try $try, project $proj)"
        json_last | jq -c '.[] | .protoPayload.metadata as $m | {timestamp, violationReason:$m.violationReason, servicePerimeter:$m.servicePerimeter, ingressViolations:$m.ingressViolations, egressViolations:$m.egressViolations, dryRun:$m.dryRun, uniqueId:$m.vpcServiceControlsUniqueId, source:$m.source, targetResource:$m.targetResource, resourceNames:$m.resourceNames}'
      } >>"$LZV_OUT_FILE"
      if grep -Eq -- "$re" <<<"$reasons"; then return 0; fi
    done
    [[ "$try" -lt 5 ]] && { note "no matching log entry yet (try $try/5); sleeping 60 s"; sleep 60; }
  done
  return 1
}

unique_id_from_last() {
  sed -nE 's/.*vpcServiceControlsUniqueIdentifier:? *"?([A-Za-z0-9_-]+).*/\1/p' "$LZV_LAST_OUT" | head -1
}

BA="$(fixture_get BUCKET_A)"; BB="$(fixture_get BUCKET_B)"

case "$BASE" in
setup)
  perimeter_guard dryrun-only
  A="$(lzv_name t13a)"; B="$(lzv_name t13b)"
  note "creating bucket A=$A (project data, inside perimeter) and bucket B=$B (project outside)"
  fixture_set BUCKET_A "$A"; fixture_set BUCKET_B "$B"
  v=()
  run_capture gcloud storage buckets create "gs://$A" --project="$(project_id data)" --location="$LZV_REGION" --uniform-bucket-level-access
  expect_success; v+=("$LZV_VERDICT")
  run_capture gcloud storage buckets create "gs://$B" --project="$(project_id outside)" --location="$LZV_REGION" --uniform-bucket-level-access
  expect_success; v+=("$LZV_VERDICT")
  run_capture_sh "printf '%s\n' '$PROBE_TEXT' | gcloud storage cp - gs://$A/$OBJ"
  expect_success; v+=("$LZV_VERDICT")
  echo "## fixtures: BUCKET_A=$A BUCKET_B=$B object=$OBJ (kept until stage copy)" >>"$LZV_OUT_FILE"
  write_stage "$(verdict_merge "${v[@]}")" "buckets $A (data) and $B (outside) created, object $OBJ uploaded"
  ;;
dryrun)
  [[ -n "$BA" && -n "$BB" ]] || lzv_die "run stage setup first (fixtures missing)"
  perimeter_guard dryrun-only
  v=(); why=""
  run_capture gcloud storage cat "gs://$BA/$OBJ"
  expect_success "$PROBE_TEXT"; v+=("$LZV_VERDICT"); [[ -n "$LZV_REASON" ]] && why+="cat: $LZV_REASON; "
  run_capture gcloud storage cp "gs://$BA/$OBJ" "gs://$BB/"
  expect_success; v+=("$LZV_VERDICT"); [[ -n "$LZV_REASON" ]] && why+="cp: $LZV_REASON; "
  if log_poll dry "" '.'; then
    why+="dry-run violations logged, violationReason=$LOG_REASONS; "
    v+=(PASS)
  else
    why+="no dry-run violation log entry found after 5 tries; "
    v+=(INCONCLUSIVE)
  fi
  write_stage "$(verdict_merge "${v[@]}")" "$why"
  ;;
outside-read)
  [[ -n "$BA" ]] || lzv_die "run stage setup first (fixtures missing)"
  perimeter_guard enforced-noingress
  run_capture gcloud storage cat "gs://$BA/$OBJ"
  expect_denied "$DENY_RE"; vd="$LZV_VERDICT"; why="$LZV_REASON"
  uid="$(unique_id_from_last)"
  note "vpcServiceControlsUniqueIdentifier extracted: ${uid:-none}"
  if [[ "$vd" == PASS || "$vd" == INCONCLUSIVE ]]; then
    if log_poll enforced "$uid" 'NO_MATCHING_ACCESS_LEVEL'; then
      why+="log violationReason=$LOG_REASONS"
    elif [[ "$LOG_ANY" -eq 1 ]]; then
      vd=FAIL; why+="log reason was $LOG_REASONS, expected NO_MATCHING_ACCESS_LEVEL"
    else
      [[ "$vd" == PASS ]] && vd=INCONCLUSIVE; why+="no enforced violation log entry found after 5 tries"
    fi
  fi
  write_stage "$vd" "$why"
  ;;
copy)
  [[ -n "$BA" && -n "$BB" ]] || lzv_die "run stage setup first (fixtures missing)"
  perimeter_guard enforced-ingress
  cleanup_trap "gcloud storage buckets describe gs://$BA --format='value(name)'"
  cleanup_trap "gcloud storage buckets describe gs://$BB --format='value(name)'"
  cleanup_trap "gcloud storage rm --recursive gs://$BB"
  cleanup_trap "gcloud storage rm --recursive gs://$BA --billing-project=$(project_id data)"
  # Bill a project inside the perimeter: with the default quota project (seed, outside) the
  # request is refused as an egress to the quota project, not because of the destination.
  run_capture gcloud storage cp "gs://$BA/$OBJ" "gs://$BB/copied.txt" --billing-project="$(project_id data)"
  expect_denied "$DENY_RE"; vd="$LZV_VERDICT"; why="$LZV_REASON"
  uid="$(unique_id_from_last)"
  note "vpcServiceControlsUniqueIdentifier extracted: ${uid:-none}"
  if [[ "$vd" == PASS || "$vd" == INCONCLUSIVE ]]; then
    if log_poll enforced "$uid" 'RESOURCES?_NOT_IN_SAME_SERVICE_PERIMETER'; then
      why+="log violationReason observed exactly: $LOG_REASONS"
      # Attribution: the egress target must be the outside project (the destination bucket),
      # not a quota/billing project.
      OUTN="$(project_number outside)"
      if json_last | jq -e --arg t "projects/$OUTN" '[.[].protoPayload.metadata.egressViolations[]? | select(.targetResource==$t)] | length > 0' >/dev/null 2>&1; then
        note "egress target is the outside project (destination bucket)"
      else
        vd=INCONCLUSIVE; why+="; egress target is not the outside project"
      fi
    elif [[ "$LOG_ANY" -eq 1 ]]; then
      vd=FAIL; why+="log reason was $LOG_REASONS, expected RESOURCES?_NOT_IN_SAME_SERVICE_PERIMETER"
    else
      [[ "$vd" == PASS ]] && vd=INCONCLUSIVE; why+="no enforced violation log entry found after 5 tries"
    fi
  fi
  write_stage "$vd" "$why"
  all=("$vd"); reasons=""
  for s in setup dryrun outside-read; do
    # use the latest attempt of each stage; list earlier attempts in the reason
    latest="$s"
    for n in 2 3 4 5 6 7 8 9; do [[ -f "$LZV_DIR/stages/$s-r$n.json" ]] && latest="$s-r$n"; done
    if [[ "$latest" != "$s" ]]; then
      reasons+="stage $s attempts: $(read_stage "$s")"
      for n in 2 3 4 5 6 7 8 9; do [[ -f "$LZV_DIR/stages/$s-r$n.json" ]] && reasons+=", r$n $(read_stage "$s-r$n")"; done
      reasons+="; "
    fi
    sv="$(read_stage "$latest")"
    if [[ "$sv" == MISSING ]]; then sv=INCONCLUSIVE; reasons+="stage $s missing; "; fi
    [[ "$sv" == PASS ]] || reasons+="stage $s: $sv; "
    all+=("$sv")
  done
  final="$(verdict_merge "${all[@]}")"
  [[ -n "$why" && "$vd" != PASS ]] && reasons+="copy: $why"
  write_result "$final" Enforced "stages setup/dryrun/outside-read/copy merged; copy: ${why:-denied as expected}" "$reasons"
  ;;
esac
