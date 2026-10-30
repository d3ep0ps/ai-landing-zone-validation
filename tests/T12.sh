#!/usr/bin/env bash
# shellcheck disable=SC2016
# T12: no direct inference grants and no fleet-wide grants for agent A (stage 1, after T11). Read-only.
set -u
source "$(dirname "$0")/lib.sh"
require_config

FOLDER="$(folder_id root)"
AI_PROD="$(folder_id ai_prod)"
ORG="$(org_id)"
RUNTIME="$(project_id runtime)"
LZV_SCOPE="organizations/$ORG"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/policy-intelligence/docs/analyze-iam-policies"
  "https://docs.cloud.google.com/iam/docs/principal-identifiers"
)

AGENT_ID="$(agents_tf '.agent_a.value.id')" || lzv_die "deploy agent A first (infra/agents output agent_a.id missing)"
TF_IDENT="$(agents_tf '.agent_a.value.identity')" || lzv_die "deploy agent A first (infra/agents output agent_a.identity missing)"
[[ "$AGENT_ID" =~ ^projects/[0-9]+/locations/[a-z0-9-]+/reasoningEngines/[0-9]+$ ]] \
  || lzv_die "agent_a.id is not a full reasoningEngines resource name"

header T12 'R2 / I3' \
  'No direct inference, no broad grants' \
  'No path found; no fleet grants. Limitation: allow policies only, direct bindings'

LIMIT="limitation: allow policies only (no deny policies), direct bindings for agent principals, best-effort analyzer freshness"

# Principal: Terraform output, or built from REST spec.effectiveIdentity if the output is a fallback.
PRINCIPAL=""
if [[ "$TF_IDENT" == principal://agents.global.* ]]; then
  PRINCIPAL="$TF_IDENT"
else
  note "terraform identity is not an agent principal ($TF_IDENT); reading spec.effectiveIdentity"
  LZV_AGENT_REGION="$(cut -d/ -f4 <<<"$AGENT_ID")"
  export LZV_AGENT_ID="$AGENT_ID" LZV_AGENT_REGION
  run_capture_sh 'printf "Authorization: Bearer %s\n" "$(gcloud auth print-access-token)" | curl -sS -H @- "https://${LZV_AGENT_REGION}-aiplatform.googleapis.com/v1beta1/${LZV_AGENT_ID}"'
  EFF="$(jq -r '.spec.effectiveIdentity // empty' "$LZV_LAST_OUT" 2>/dev/null)"
  [[ -n "$EFF" ]] && PRINCIPAL="principal://${EFF#principal://}"
fi
if [[ -z "$PRINCIPAL" ]]; then
  write_result INCONCLUSIVE Enforced "no agent principal available" "could not resolve the agent principal; $LIMIT"
  exit 0
fi
note "agent principal: $PRINCIPAL"

# (1) Confirm the inference permission name.
run_capture gcloud iam roles describe roles/aiplatform.user --format=json
if [[ "$LZV_LAST_RC" != 0 ]] || ! last_output_matches 'aiplatform\.endpoints\.predict'; then
  write_result INCONCLUSIVE Enforced "aiplatform.endpoints.predict not confirmed in roles/aiplatform.user (exit $LZV_LAST_RC)" \
    "permission name could not be confirmed; $LIMIT"
  exit 0
fi

# Count analyzer results. gcloud prints a status line before the JSON, and the JSON is a
# top-level array of {ACLs, policy} (fixed 2026-10-25 after Phase 6: the old path
# .mainAnalysis.analysisResults never matched, so runs 1 and 2 recorded 0 although results exist).
analysis_count() {
  local n
  n="$(awk '/^[[{]/{on=1} on{print} on && /^[]}]$/{exit}' "$1" \
    | jq 'if type == "array" then length else ([.mainAnalysis.analysisResults[]?] | length) end' 2>/dev/null)"
  echo "${n:-0}"
}

# (2) Positive control: the operator must show up for a permission it surely has.
export LZV_ORG="$ORG" LZV_RT="$RUNTIME" LZV_PRINCIPAL="$PRINCIPAL"
run_capture_sh 'gcloud asset analyze-iam-policy --organization="$LZV_ORG" --identity="user:$(gcloud config get account)" --permissions=resourcemanager.folders.get --billing-project="$LZV_RT" --format=json'
CONTROL_RC=$LZV_LAST_RC
CONTROL_N="$(analysis_count "$LZV_LAST_OUT")"
note "positive control: exit $CONTROL_RC, analysis results = $CONTROL_N"

# (3) Agent queries: permission, then roles.
ANALYZER_FOUND=0
ANALYZER_USABLE=1
for q in "--permissions=aiplatform.endpoints.predict" "--roles=roles/aiplatform.expressUser,roles/aiplatform.user"; do
  run_capture gcloud asset analyze-iam-policy --organization="$ORG" --identity="$PRINCIPAL" "$q" --billing-project="$RUNTIME" --format=json
  if [[ "$LZV_LAST_RC" != 0 ]]; then
    ANALYZER_USABLE=0
    note "analyzer failed for $q (exit $LZV_LAST_RC); first error line: $(head -c 300 "$LZV_LAST_OUT" | head -1)"
  else
    n="$(analysis_count "$LZV_LAST_OUT")"
    note "agent analyzer $q: analysis results = $n"
    [[ "$n" -gt 0 ]] && ANALYZER_FOUND=1
  fi
done

# (4) Direct inspection of allow policies on runtime project, ai_prod folder, root folder, org.
INSPECT_OK=1
FLEET=""
INFER=""
DEFAULTS=""
inspect() {  # inspect LABEL CMD...
  local label="$1"; shift
  run_capture "$@" --format=json
  if [[ "$LZV_LAST_RC" != 0 ]]; then
    INSPECT_OK=0
    note "inspect $label: read failed (exit $LZV_LAST_RC)"
    return
  fi
  local all fleet infer defs
  all="$(jq -r '[.bindings[]? | .role as $r | .members[]? | select(contains("agents.global")) | "\($r) \(.)"] | join("; ")' "$LZV_LAST_OUT")"
  fleet="$(jq -r '[.bindings[]? | .role as $r | .members[]? | select(startswith("principalSet://") and contains("agents.global")) | "\($r) \(.)"] | join("; ")' "$LZV_LAST_OUT")"
  infer="$(jq -r --arg p "$PRINCIPAL" '[.bindings[]? | select(.role | IN("roles/aiplatform.user","roles/aiplatform.expressUser","roles/aiplatform.admin","roles/owner","roles/editor")) | .role as $r | .members[]? | select(. == $p) | "\($r) \(.)"] | join("; ")' "$LZV_LAST_OUT")"
  defs="$(jq -r --arg p "$PRINCIPAL" '[.bindings[]? | select(.role | IN("roles/aiplatform.agentDefaultAccess","roles/aiplatform.agentContextEditor")) | .role as $r | .members[]? | select(. == $p) | $r] | join(", ")' "$LZV_LAST_OUT")"
  note "inspect $label: agents.global members: ${all:-none}"
  [[ -n "$fleet" ]] && FLEET="$FLEET [$label] $fleet"
  [[ -n "$infer" ]] && INFER="$INFER [$label] $infer"
  [[ -n "$defs" ]] && DEFAULTS="$DEFAULTS [$label] $defs"
}
inspect "project runtime" gcloud projects get-iam-policy "$RUNTIME"
inspect "folder ai_prod" gcloud resource-manager folders get-iam-policy "$AI_PROD"
inspect "folder root" gcloud resource-manager folders get-iam-policy "$FOLDER"
inspect "organization" gcloud organizations get-iam-policy "$ORG"
note "observation, agent default roles on the agent principal:${DEFAULTS:- none found}"

if [[ "$ANALYZER_FOUND" == 1 || -n "$FLEET" || -n "$INFER" ]]; then
  VERDICT=FAIL
  REASON="found: analyzer_results=$ANALYZER_FOUND fleet_grants=[${FLEET:-none}] inference_bindings=[${INFER:-none}]; $LIMIT"
elif [[ "$CONTROL_RC" != 0 || "$CONTROL_N" -lt 1 ]]; then
  VERDICT=INCONCLUSIVE
  REASON="positive control returned no results (exit $CONTROL_RC, n=$CONTROL_N), so an empty agent query proves nothing; $LIMIT"
elif [[ "$INSPECT_OK" != 1 ]]; then
  VERDICT=INCONCLUSIVE
  REASON="direct policy inspection incomplete (analyzer usable=$ANALYZER_USABLE); $LIMIT"
else
  VERDICT=PASS
  REASON="positive control returned $CONTROL_N result(s); analyzer usable=$ANALYZER_USABLE (if 0, rely on direct inspection); $LIMIT"
fi
echo "T12 -> $VERDICT"

write_result "$VERDICT" Enforced \
  "control results=$CONTROL_N; analyzer found path=$ANALYZER_FOUND; fleet grants=${FLEET:-none}; inference bindings=${INFER:-none}" \
  "$REASON"
