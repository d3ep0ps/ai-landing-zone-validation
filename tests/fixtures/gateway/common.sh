# shellcheck shell=bash
# Shared by setup.sh and teardown.sh (v2 B). Reads project data from the infra/ state; no IDs in the repo.
# Safety: active gcloud configuration must be lz-validation. Never --quiet; no token is written to a file.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
REGION="${LZV_REGION:-europe-west1}"
OUT_DIR="$ROOT/scratch"; mkdir -p "$OUT_DIR"

die() { echo "ABORT: $*" >&2; exit 2; }

cfg="$(gcloud config configurations list --filter=is_active:true --format='value(name)' 2>/dev/null)"
[[ "$cfg" == "lz-validation" ]] || die "active gcloud configuration is '$cfg', expected 'lz-validation'"

TFJ="$(terraform -chdir="$ROOT/infra" output -json 2>/dev/null)" || die "cannot read infra/ outputs"
P="$(jq -er '.project_ids.value.runtime' <<<"$TFJ")" || die "no runtime project in infra/ outputs"
PN="$(jq -er '.project_numbers.value.runtime' <<<"$TFJ")" || die "no runtime project number"
REG_SVC="${LZV_MCP_REG_SERVICE:-lzv-mcp-reg}"
UNREG_SVC="${LZV_MCP_UNREG_SERVICE:-lzv-mcp-unreg}"
GW_PREFLIGHT="lzv-gw-preflight"
IMAGE="$REGION-docker.pkg.dev/$P/lzv-gw/mcp:v1"

# REST call with the token piped on stdin (curl -H @-), as tests/T27.sh ma_delete_cmd does.
rest() {  # rest METHOD URL
  printf 'Authorization: Bearer %s\nx-goog-user-project: %s\n' "$(gcloud auth print-access-token)" "$P" \
    | curl -sS --max-time 60 -H @- -X "$1" "$2" -w '\nHTTP %{http_code}\n'
}
