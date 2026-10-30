#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2119
# T01: service account key creation blocked (iam.managed.disableServiceAccountKeyCreation)
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_config

P="$(project_id runtime)"
LZV_SCOPE="projects/$P"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/resource-manager/docs/organization-policy/restricting-service-accounts"
  "https://docs.cloud.google.com/organization-policy/reference/org-policy-constraints"
)

header T01 I2 \
  '`iam.managed.disableServiceAccountKeyCreation` (managed constraint, not the legacy `iam.disableServiceAccountKeyCreation`) (folder)' \
  'Denied with `FAILED_PRECONDITION`; error names the managed constraint or says "Key creation is not allowed"'

SA_NAME="$(lzv_name t01)"
SA="$SA_NAME@$P.iam.gserviceaccount.com"
mkdir -p "$LZV_ROOT/scratch"
KEYDIR="$(mktemp -d "$LZV_ROOT/scratch/lzv-t01.XXXXXX")"
KEYFILE="$KEYDIR/key.json"

# Cleanup is LIFO: the SA is deleted first, then the existence check, then the key directory.
cleanup_trap "rm -rf $KEYDIR"
cleanup_trap "gcloud iam service-accounts describe $SA --project=$P"
cleanup_trap "gcloud iam service-accounts delete $SA --project=$P"

# Effective policy first (read-only).
effective_policy constraints/iam.managed.disableServiceAccountKeyCreation "--project=$P"
EFF="$(jq -c '[.spec.rules[]? | .enforce] | first // "unset"' "$LZV_LAST_OUT" 2>/dev/null || echo unreadable)"
note "effective constraints/iam.managed.disableServiceAccountKeyCreation on $P: enforce=$EFF"

if ! run_capture gcloud iam service-accounts create "$SA_NAME" --project="$P" --display-name="lzv T01 test SA"; then
  write_result INCONCLUSIVE Enforced "test service account could not be created" "SA creation failed (see output.txt); no attempt made"
  exit 0
fi
sleep 15   # IAM propagation for the new SA

run_capture gcloud iam service-accounts keys create "$KEYFILE" --iam-account="$SA" --project="$P"
expect_denied 'FAILED_PRECONDITION' 'Key creation is not allowed|iam\.managed\.disableServiceAccountKeyCreation'
VERDICT="$LZV_VERDICT"; REASON="$LZV_REASON"

if [[ "$LZV_LAST_RC" == 0 ]]; then
  # Unexpected success: delete every user-managed key at once, never keep it.
  note "key creation SUCCEEDED; deleting key(s) and key file"
  run_capture gcloud iam service-accounts keys list --iam-account="$SA" --managed-by=user --format='value(name)'
  IDS="$(cat "$LZV_LAST_OUT")"
  for k in $IDS; do
    run_capture gcloud iam service-accounts keys delete "${k##*/}" --iam-account="$SA"
  done
  run_capture gcloud iam service-accounts keys list --iam-account="$SA" --managed-by=user
  rm -f "$KEYFILE"
  VERDICT=FAIL; REASON="key creation succeeded although denial was expected (key deleted)"
fi
rm -f "$KEYFILE"

if [[ "$VERDICT" == PASS ]]; then
  write_result PASS Enforced "key creation denied with FAILED_PRECONDITION and the verified signature (effective enforce=$EFF)"
else
  write_result "$VERDICT" Enforced "attempt verdict $VERDICT (effective enforce=$EFF)" "$REASON"
fi
