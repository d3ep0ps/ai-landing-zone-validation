#!/usr/bin/env bash
# T46 (v3 B7): DPoP as the way to keep token binding behind the gateway. Plan: plans/v3-harness-boundary-tests.md T46.
# Expected is "record outcome"; NOT_TESTED is acceptable with links and dates. The doc check
# (notes/doc-verification-v3h.md section T46, accessed 2026-11-10) found a documented design but no documented way to
# enable or verify DPoP from the agent, no DPoP code in google-auth 2.62.1 / google-cloud-aiplatform 2.6.0 /
# google-adk 2.13.0, and no doc or release note saying it works end to end for a Vertex AI call through Agent Gateway.
# So this script records that evidence and writes NOT_TESTED. It changes nothing in the cloud.
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_config

LZV_SCOPE="folders/$(folder_id root)"
LZV_DOC_REFS=(
  "https://docs.cloud.google.com/access-context-manager/docs/caa-agent-security"
  "https://docs.cloud.google.com/gemini-enterprise-agent-platform/release-notes"
  "https://pypi.org/project/google-auth/"
  "https://github.com/googleapis/python-aiplatform/issues/7209"
)
header T46 "B7 (Documented)" "DPoP support for agent tokens through Agent Gateway; control: none (documentation and package-source check)" \
  "unknown, so pre-register \"record outcome\". NOT_TESTED is acceptable with links and dates."
note "plan claim B7; no resources are created; no cleanup_trap registered"

NOTES_FILE="$LZV_ROOT/notes/doc-verification-v3h.md"
[[ -f "$NOTES_FILE" ]] || guard_abort "notes/doc-verification-v3h.md not found"
# Copy of the documentation evidence (dates, URLs, quotes) into the evidence directory.
sed -n '/^## T46/,/^## T47/p' "$NOTES_FILE" | sed '$d' >"$LZV_DIR/doc-evidence.txt"
[[ -s "$LZV_DIR/doc-evidence.txt" ]] || guard_abort "T46 section not found in $NOTES_FILE"
{
  echo "# recorded $(lzv_ts) by tests/T46.sh"
  echo "# docs accessed 2026-11-10; sources: the URLs below"
  grep -Eo 'https://[^ ;)]+' "$LZV_DIR/doc-evidence.txt" | sort -u
  echo "# pinned versions in the agent fixtures (requirements.txt):"
  grep -hE '^(google-auth|google-adk|google-cloud-aiplatform)' "$LZV_ROOT/tests/fixtures/gateway/agent_g/requirements.txt" "$LZV_ROOT/tests/fixtures/agent_v3/requirements.txt" 2>/dev/null
} >"$LZV_DIR/doc-urls.txt"
note "doc evidence copied to ${LZV_DIR#"$LZV_ROOT"/}/doc-evidence.txt and doc-urls.txt"
note "doc finding: design = CAA with DPoP (RFC 9449) when the gateway terminates mTLS; client-side support in google-auth 2.62.1, google-cloud-aiplatform 2.6.0, google-adk 2.13.0: none found; end-to-end status for Vertex AI through Agent Gateway: not found; only release-note mention 2026-08-31 (CAA with DPoP in Unified Access Policies GA)"

not_tested Documented "documented design only (CAA with DPoP, docs accessed 2026-11-10); no documented switch to enable or verify DPoP from the agent, no DPoP code in google-auth 2.62.1, google-cloud-aiplatform 2.6.0 or google-adk 2.13.0, and no doc or release note stating it works end to end for Vertex AI through Agent Gateway. Only lever would be on the gateway/IAP side, not agent code. Evidence: doc-evidence.txt"
