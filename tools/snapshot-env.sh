#!/usr/bin/env bash
# Read-only snapshot of the reference environment for Gate 2.
# Raw output goes to scratch/snapshot-raw/ (git-ignored); a redacted copy goes to
# evidence/environment/. Runs only gcloud describe/list and terraform output.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RAW="$ROOT/scratch/snapshot-raw"
OUT="$ROOT/evidence/environment"
rm -rf "$RAW"   # scratch only; stale files would be copied into the evidence snapshot
mkdir -p "$RAW" "$OUT"

# Safety: right gcloud configuration only.
active="$(gcloud config configurations list --filter=is_active=true --format='value(name)')"
if [[ "$active" != "lz-validation" ]]; then
  echo "active gcloud configuration is '$active', expected lz-validation; stopping" >&2
  exit 1
fi

tf_out="$(terraform -chdir="$ROOT/infra" output -json)"
folder_root="$(jq -r '.folder_ids.value.root' <<<"$tf_out" | sed 's#folders/##')"
folder_prod="$(jq -r '.folder_ids.value.ai_prod' <<<"$tf_out" | sed 's#folders/##')"
org_id="$(gcloud resource-manager folders describe "$folder_root" --format='value(parent)' | sed 's#organizations/##')"

run() { # run NAME CMD...: save stdout+stderr, never fail the whole snapshot
  local name="$1"; shift
  { echo "\$ $*"; "$@" 2>&1 || echo "EXIT=$?"; } > "$RAW/$name.txt"
}

{
  echo "snapshot_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gcloud --version | head -1
  terraform version | head -1
  echo "fabric=$(git -C "$ROOT/vendor/fabric" rev-parse HEAD)"
} > "$RAW/00-versions.txt"

jq '{folder_ids, project_ids, project_numbers}' <<<"$tf_out" > "$RAW/01-terraform-output.json"
run 02-folders-under-root gcloud resource-manager folders list --folder="$folder_root" --format=json
run 03-projects gcloud projects list --filter="parent.id=$folder_root OR parent.id=$folder_prod" --format='json(projectId,parent,lifecycleState)'

# Effective policy per constraint under test (Appendix A). T05/T06/T07 are toggled off
# on the first apply; their effective value is still recorded.
constraints=(
  iam.managed.disableServiceAccountKeyCreation   # T01
  run.managed.requireInvokerIam                  # T02
  run.allowedIngress                             # T03
  vertexai.configurableComputerUseToolSafetyPolicies # T05
  discoveryengine.managed.disableCustomMcpServerConnector # T06
  gcp.restrictNonCmekServices                    # T07, T10
  gcp.resourceLocations                          # T08
  storage.publicAccessPrevention                 # T09
  run.allowedBinaryAuthorizationPolicies         # T17
)
for c in "${constraints[@]}"; do
  run "10-effective-root-$c" gcloud org-policies describe "$c" --folder="$folder_root" --effective --format=json
done
run "10-effective-aiprod-vertexai.allowedModels" gcloud org-policies describe vertexai.allowedModels --folder="$folder_prod" --effective --format=json

# VPC-SC: access policies and perimeters (dry-run spec and enforced status).
run 20-access-policies gcloud access-context-manager policies list --organization="$org_id" --format=json
# File names use an index, not the policy number (the number is redacted inside the file).
i=0
for p in $(gcloud access-context-manager policies list --organization="$org_id" --format='value(name)'); do
  i=$((i + 1))
  run "21-perimeters-$i" gcloud access-context-manager perimeters list --policy="$p" --format=json
done

# T15 log bucket.
data_project="$(jq -r '.project_ids.value.data' <<<"$tf_out")"
run 30-log-bucket gcloud logging buckets describe lzv-locked-logs --location=europe-west1 --project="$data_project" --format=json

# Redacted copy for evidence.
rm -rf "$OUT/snapshot"
cp -R "$RAW" "$OUT/snapshot"
python3 "$ROOT/tools/redact.py" "$OUT/snapshot" >/dev/null
python3 "$ROOT/tools/redact.py" --check "$OUT/snapshot"
echo "snapshot: $OUT/snapshot ($(find "$OUT/snapshot" -type f | wc -l | tr -d ' ') files)"
