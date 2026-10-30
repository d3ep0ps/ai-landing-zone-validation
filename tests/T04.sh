#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2119
# T04: model allowlist (vertexai.allowedModels), REST generateContent
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_config

P="$(project_id runtime)"
LZV_SCOPE="projects/$P (folder $(folder_id ai_prod))"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/vertex-ai/generative-ai/docs/control-model-access"
  "https://docs.cloud.google.com/organization-policy/reference/org-policy-constraints"
)

DENIED="${T04_DENIED_MODEL:-}"
[[ -n "$DENIED" ]] || lzv_die "T04_DENIED_MODEL is not set (a Google model that is NOT on the allowlist)"
LOC="${T04_LOCATION:-global}"
[[ "$DENIED" =~ ^[A-Za-z0-9._-]+$ ]] || lzv_die "T04_DENIED_MODEL has unexpected characters"
[[ "$LOC" =~ ^[a-z0-9-]+$ ]] || lzv_die "T04_LOCATION has unexpected characters"
[[ "$P" =~ ^[a-z0-9-]+$ ]] || lzv_die "project id has unexpected characters"

header T04 P1 \
  '`vertexai.allowedModels` allowlist with `:predict` suffix (prod folder)' \
  'Non-listed model denied, error names `vertexai.allowedModels`; control succeeds'

if [[ "$LOC" == global ]]; then HOST="aiplatform.googleapis.com"; else HOST="$LOC-aiplatform.googleapis.com"; fi

# Allowlist from the effective policy.
effective_policy constraints/vertexai.allowedModels "--project=$P"
ALLOWED_RAW="$(jq -r '[.spec.rules[]? | .values.allowedValues[]?] | .[]' "$LZV_LAST_OUT" 2>/dev/null)"
# Normalised model names: strip is:, publishers/google/models/ and :predict
ALLOWED_LIST="$(printf '%s\n' "$ALLOWED_RAW" | sed -e 's/^is://' -e 's#^publishers/google/models/##' -e 's/:predict$//' | grep -v '^$')"
if [[ -z "$ALLOWED_LIST" ]]; then
  write_result INCONCLUSIVE Configured "no allowedValues in the effective vertexai.allowedModels policy" \
    "effective policy has no allowlist; cannot choose an allowed model"
  exit 0
fi
ALLOWED="$(printf '%s\n' "$ALLOWED_LIST" | grep -E '^[A-Za-z0-9._-]+$' | head -1)"
[[ -n "$ALLOWED" ]] || guard_abort "no usable allowed model in the effective policy"
if printf '%s\n' "$ALLOWED_LIST" | grep -Fxq -- "$DENIED"; then
  guard_abort "T04_DENIED_MODEL '$DENIED' is on the allowlist; choose a model that is not"
fi
note "allowed model (control): $ALLOWED; denied model (attempt): $DENIED; location: $LOC; host: $HOST"

BODY='{"contents":[{"role":"user","parts":[{"text":"Reply OK"}]}],"generationConfig":{"maxOutputTokens":5}}'

# Build the shell string; project/model/location are substituted now, the token command stays
# literal so the token is never written to a file. rc is 0 only for HTTP 200.
gen_cmd() {  # gen_cmd MODEL
  local url="https://$HOST/v1/projects/$P/locations/$LOC/publishers/google/models/$1:generateContent"
  # shellcheck disable=SC2016
  printf '%s' 'out=$(printf "Authorization: Bearer %s\n" "$(gcloud auth print-access-token)" | curl -sS -H @- -H "Content-Type: application/json" -d '"'$BODY'"' -w "\nHTTP %{http_code}\n" '"'$url'"'); printf "%s\n" "$out"; code=$(printf "%s\n" "$out" | sed -n "s/^HTTP //p" | tail -1); [ "$code" = 200 ]'
}

# Positive control.
run_capture_sh "$(gen_cmd "$ALLOWED")"
expect_success 'HTTP 200'
V_CTRL="$LZV_VERDICT"; R_CTRL="$LZV_REASON"

# Attempt with the non-listed model.
run_capture_sh "$(gen_cmd "$DENIED")"
expect_denied 'vertexai\.allowedModels'
V_DENY="$LZV_VERDICT"; R_DENY="$LZV_REASON"

if [[ "$V_CTRL" != PASS ]]; then
  FINAL=INCONCLUSIVE; TIER=Configured
  REASON="positive control failed: $R_CTRL"
elif [[ "$V_DENY" == PASS ]]; then
  FINAL=PASS; TIER=Enforced; REASON=""
else
  FINAL="$V_DENY"; TIER=Configured; REASON="$R_DENY"
fi

ACTUAL="allowed model $ALLOWED: $V_CTRL; non-listed model $DENIED: $V_DENY (location $LOC)"
if [[ "$FINAL" == PASS ]]; then
  write_result PASS "$TIER" "$ACTUAL"
else
  write_result "$FINAL" "$TIER" "$ACTUAL" "$REASON"
fi
