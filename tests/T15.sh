#!/usr/bin/env bash
# T15: locked log bucket rejects a retention change.
# shellcheck disable=SC2016,SC2119
set -u
source "$(dirname "$0")/lib.sh"
require_config

LZV_SCOPE="project/log bucket from terraform output log_bucket_id"
LZV_DOC_REFS=("https://docs.cloud.google.com/logging/docs/buckets")
header T15 I6 "Locked log bucket" '`locked: true`; change denied'

json_last() { sed -n '/^[[{]/,$p' "$LZV_LAST_OUT"; }

BID="$(lzv_tf '.log_bucket_id.value')"
IFS=/ read -r _ P _ L _ B <<<"$BID"
[[ -n "$P" && -n "$L" && -n "$B" ]] || lzv_die "cannot parse log_bucket_id"
LZV_SCOPE="projects/$P/locations/$L/buckets/$B"
note "target bucket $LZV_SCOPE; no cleanup registered: the lock is irreversible and the bucket is kept (empty, so still deletable)"

run_capture gcloud logging buckets describe "$B" --location="$L" --project="$P" --format=json
locked="$(json_last | jq -r '.locked // false')"
ret="$(json_last | jq -r '.retentionDays // empty')"
if [[ "$locked" != true || "$ret" != 1 ]]; then
  not_tested Configured "precondition not met: locked=$locked retentionDays=${ret:-unset} (need locked=true, retentionDays=1)"
fi

run_capture gcloud logging buckets update "$B" --location="$L" --project="$P" --retention-days=2
expect_denied '[Ll]ocked|FAILED_PRECONDITION'
verdict="$LZV_VERDICT"; reason="$LZV_REASON"

run_capture gcloud logging buckets describe "$B" --location="$L" --project="$P" --format=json
after="$(json_last | jq -r '.retentionDays // "unknown"')"
actual="locked=true, retentionDays before=1; update to 2 days -> $verdict; retentionDays after=$after"
if [[ "$verdict" == FAIL ]]; then
  note "update succeeded: bucket retention is now 2 days and cannot be lowered (bucket is empty, so still deletable)"
  reason="$reason; bucket retention is now 2 days (cannot be lowered; empty bucket is still deletable)"
fi
write_result "$verdict" Enforced "$actual" "$reason"
