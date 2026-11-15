#!/usr/bin/env bash
# Build the v3 agent tarball once and write identical bytes to both consumers:
#   infra/agents/build/source-v3.tar.gz and infra-v3h/build/source.tar.gz. Prints the sha256.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
out1_dir="$root/infra/agents/build"
out2_dir="$root/infra-v3h/build"
mkdir -p "$out1_dir" "$out2_dir"
stage="$(mktemp -d)"
tmp_out="$(mktemp)"
trap 'rm -rf "$stage" "$tmp_out"' EXIT

# Variant "dep" (T45d, plan 3b): same files plus the lzv_helper package, one import line and one requirements line.
variant="${1:-}"
files=(agent.py probes.py requirements.txt)
for f in "${files[@]}"; do
  cp "$here/$f" "$stage/$f"
  touch -t 202001010000 "$stage/$f"
done
if [[ "$variant" == dep ]]; then
  out1_dir="$root/infra/agents/build"; out2_dir=""
  mkdir -p "$stage/lzv_helper/lzv_helper"
  cp "$here/lzv_helper/pyproject.toml" "$stage/lzv_helper/pyproject.toml"
  cp "$here/lzv_helper/lzv_helper/__init__.py" "$stage/lzv_helper/lzv_helper/__init__.py"
  printf './lzv_helper\n' >>"$stage/requirements.txt"
  python3 - "$stage/agent.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
a = "import probes\n"
assert s.count(a) == 1
open(p, "w").write(s.replace(a, a + "import lzv_helper  # noqa: F401  (T45d: third-party-style utility)\n"))
PY
  find "$stage" -exec touch -t 202001010000 {} +
  files+=(lzv_helper)
fi

# Prefer GNU tar for determinism (sorted, fixed mtime, numeric owner); fall back to bsdtar (files listed sorted).
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  tar --sort=name --mtime='2020-01-01 00:00:00' --owner=0 --group=0 --numeric-owner \
    -C "$stage" -cf - "${files[@]}" | gzip -n >"$tmp_out"
else
  tar --uid 0 --gid 0 --numeric-owner -C "$stage" -cf - "${files[@]}" | gzip -n >"$tmp_out"
fi
if [[ "$variant" == dep ]]; then
  cp "$tmp_out" "$out1_dir/source-v3d.tar.gz"
  echo "wrote $out1_dir/source-v3d.tar.gz"
  shasum -a 256 "$out1_dir/source-v3d.tar.gz"
else
  cp "$tmp_out" "$out1_dir/source-v3.tar.gz"
  cp "$tmp_out" "$out2_dir/source.tar.gz"
  echo "wrote $out1_dir/source-v3.tar.gz"
  echo "wrote $out2_dir/source.tar.gz"
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$out1_dir/source-v3.tar.gz" "$out2_dir/source.tar.gz"; else shasum -a 256 "$out1_dir/source-v3.tar.gz" "$out2_dir/source.tar.gz"; fi
fi
tar -tzf "$tmp_out"
