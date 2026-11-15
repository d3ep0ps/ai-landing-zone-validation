#!/usr/bin/env bash
# shellcheck disable=SC2016
# T11: per-agent identity of agent A (stage 1, after the human deployed agent A via infra/agents).
set -u
source "$(dirname "$0")/lib.sh"
require_config

FOLDER="$(folder_id root)"
ORG="$(org_id)"
LZV_SCOPE="folders/$FOLDER"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/agent-identity"
  "https://docs.cloud.google.com/agent-builder/agent-engine/agent-identity"
  "https://docs.cloud.google.com/iam/docs/principal-identifiers"
)

AGENT_ID="$(agents_tf '.agent_a.value.id')" || lzv_die "deploy agent A first (infra/agents output agent_a.id missing)"
TF_IDENT="$(agents_tf '.agent_a.value.identity')" || lzv_die "deploy agent A first (infra/agents output agent_a.identity missing)"
[[ "$AGENT_ID" =~ ^projects/[0-9]+/locations/[a-z0-9-]+/reasoningEngines/[0-9]+$ ]] \
  || lzv_die "agent_a.id is not a full reasoningEngines resource name"
AGENT_REGION="$(cut -d/ -f4 <<<"$AGENT_ID")"
ENGINE="$(cut -d/ -f6 <<<"$AGENT_ID")"

header T11 I1 \
  'Per-agent identity (module default `AGENT_IDENTITY`; platform default is a service account)' \
  'Unique `principal://agents.global.org-…/…/reasoningEngines/ID`; no SA email'
note "module default identity_type is AGENT_IDENTITY; the raw API/SDK default is a service account (docs), so this observes the module default"

# 1. Terraform output (captured).
run_capture terraform -chdir="$LZV_ROOT/infra/agents" output -json agent_a

# 2. REST GET of the reasoning engine (token never written to a file).
export LZV_AGENT_ID="$AGENT_ID" LZV_AGENT_REGION="$AGENT_REGION"
run_capture_sh 'printf "Authorization: Bearer %s\n" "$(gcloud auth print-access-token)" | curl -sS -H @- "https://${LZV_AGENT_REGION}-aiplatform.googleapis.com/v1beta1/${LZV_AGENT_ID}"'
REST_RC=$LZV_LAST_RC
EFF="$(jq -r '.spec.effectiveIdentity // empty' "$LZV_LAST_OUT" 2>/dev/null)"
REST_IDENT=""
[[ -n "$EFF" ]] && REST_IDENT="principal://${EFF#principal://}"

PREFIX="principal://agents.global.org-${ORG}.system.id.goog/"
ident_ok() { [[ "$1" == "$PREFIX"* && "$1" == *"/reasoningEngines/$ENGINE" && "$1" != *gserviceaccount.com* ]]; }

note "terraform identity: $TF_IDENT"
note "REST spec.effectiveIdentity (as principal://): ${REST_IDENT:-<missing>} (curl exit $REST_RC)"
note "expected prefix: $PREFIX ; engine id: $ENGINE"

if [[ "$TF_IDENT" == *gserviceaccount.com* || "$REST_IDENT" == *gserviceaccount.com* ]]; then
  VERDICT=FAIL
  REASON="a service account identity was reported (fallback): agent identity was not in effect"
elif [[ "$REST_RC" != 0 || -z "$REST_IDENT" || -z "$TF_IDENT" ]]; then
  VERDICT=INCONCLUSIVE
  REASON="could not read both the Terraform output and spec.effectiveIdentity (REST curl exit $REST_RC)"
elif ident_ok "$TF_IDENT" && ident_ok "$REST_IDENT"; then
  VERDICT=PASS
  REASON="observation of the module default for one deployed agent; says nothing about other agents or the platform default"
else
  VERDICT=FAIL
  REASON="identity does not match principal://agents.global.org-<org>.system.id.goog/.../reasoningEngines/<id>"
fi
echo "T11 -> $VERDICT"

write_result "$VERDICT" Enforced \
  "terraform identity: $TF_IDENT ; REST effectiveIdentity: ${REST_IDENT:-missing}" \
  "$REASON"
