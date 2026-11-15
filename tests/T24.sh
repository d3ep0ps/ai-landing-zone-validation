#!/usr/bin/env bash
# shellcheck disable=SC2016
# T24 (v1.1, DC4): Admin Activity entry routed to the locked bucket; retention change still refused.
# Needs enable_dc4_sink=true and log_bucket_locked=true. Entries written to the locked bucket persist for its retention.
set -u
source "$(dirname "$0")/lib.sh"
require_config

FOLDER="$(folder_id root)"
RUNTIME="$(project_id runtime)"
LZV_SCOPE="folders/$FOLDER"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/logging/docs/export/aggregated_sinks"
  "https://docs.cloud.google.com/logging/docs/routing/overview"
  "https://docs.cloud.google.com/logging/docs/buckets"
)

header T24 I6 DC4 \
  'The entry appears in the locked bucket within 15 min (writing to a locked bucket is not documented either way); retention change still refused'

json_last() { sed -n '/^[[{]/,$p' "$LZV_LAST_OUT"; }

BID="$(lzv_tf '.log_bucket_id.value')"
IFS=/ read -r _ P _ L _ B <<<"$BID"
[[ -n "$P" && -n "$L" && -n "$B" ]] || lzv_die "cannot parse log_bucket_id"

# Guards: sink exists, bucket locked with retention 1.
run_capture gcloud logging sinks describe lzv-dc4-admin-activity --folder="$FOLDER" --format=json
[[ "$LZV_LAST_RC" == 0 ]] || guard_abort "sink lzv-dc4-admin-activity not found on the folder: set enable_dc4_sink=true"
run_capture gcloud logging buckets describe "$B" --location="$L" --project="$P" --format=json
locked="$(json_last | jq -r '.locked // false')"
ret="$(json_last | jq -r '.retentionDays // empty')"
[[ "$locked" == true && "$ret" == 1 ]] || guard_abort "bucket needs locked=true and retentionDays=1 (got locked=$locked retention=${ret:-unset})"

# Admin action: create then delete a service account (no keys).
SA="lzv-t24-probe-$(date +%s)"
SA_EMAIL="$SA@$RUNTIME.iam.gserviceaccount.com"
cleanup_trap "if gcloud iam service-accounts describe $SA_EMAIL --project=$RUNTIME >/dev/null 2>&1; then gcloud iam service-accounts delete $SA_EMAIL --project=$RUNTIME; fi; if gcloud iam service-accounts describe $SA_EMAIL --project=$RUNTIME >/dev/null 2>&1; then echo 'CLEANUP CHECK: service account still exists'; else echo 'CLEANUP CHECK: service account gone'; fi"
run_capture gcloud iam service-accounts create "$SA" --project="$RUNTIME"
if [[ "$LZV_LAST_RC" != 0 ]]; then
  write_result INCONCLUSIVE Enforced "probe service account creation failed (exit $LZV_LAST_RC); no admin action to route" \
    "admin action could not be performed"
  exit 0
fi
note "probe service account $SA created in the runtime project"

# Poll the locked bucket: every 60 s, up to 15 min.
FILTER="protoPayload.methodName=\"google.iam.admin.v1.CreateServiceAccount\" AND \"$SA\""
FOUND=0
for try in $(seq 1 15); do
  run_capture gcloud logging read "$FILTER" --bucket="$B" --location="$L" --view=_AllLogs --project="$P" --freshness=1h --limit=5 --format=json
  if [[ "$LZV_LAST_RC" == 0 ]] && grep -q "$SA" "$LZV_LAST_OUT"; then FOUND="$try"; break; fi
  [[ "$try" -lt 15 ]] && sleep 60
done
if [[ "$FOUND" != 0 ]]; then
  V1=PASS; R1=""; A1="entry found in the locked bucket after $FOUND poll(s)"
else
  V1=FAIL; R1="no CreateServiceAccount entry for the probe in the locked bucket within 15 min"; A1="entry not found in 15 polls"
fi

# Retention raise 1 -> 2, as T15.
run_capture gcloud logging buckets update "$B" --location="$L" --project="$P" --retention-days=2
expect_denied '[Ll]ocked|FAILED_PRECONDITION'
V2="$LZV_VERDICT"; R2="$LZV_REASON"
run_capture gcloud logging buckets describe "$B" --location="$L" --project="$P" --format=json
after="$(json_last | jq -r '.retentionDays // "unknown"')"

V="$(verdict_merge "$V1" "$V2")"
REASON=""
[[ "$V1" == PASS ]] || REASON+="routing: $R1; "
[[ "$V2" == PASS ]] || REASON+="retention change: $R2; "
write_result "$V" Enforced \
  "$A1; retention 1 -> 2 days: $V2; retentionDays after=$after" \
  "$REASON"
