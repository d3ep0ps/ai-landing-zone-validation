#!/usr/bin/env bash
# Build infra/agents/build/source.tar.gz with agent.py and requirements.txt at the tarball root.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out_dir="$here/../../../infra/agents/build"
mkdir -p "$out_dir"
out="$(cd "$out_dir" && pwd)/source.tar.gz"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

files=(agent.py requirements.txt)
for f in "${files[@]}"; do
  cp "$here/$f" "$stage/$f"
  touch -t 202001010000 "$stage/$f"
done

# Prefer GNU tar for determinism (sorted, fixed mtime, numeric owner); fall back to bsdtar.
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  tar --sort=name --mtime='2020-01-01 00:00:00' --owner=0 --group=0 --numeric-owner \
    -C "$stage" -cf - "${files[@]}" | gzip -n >"$out"
else
  tar --uid 0 --gid 0 --numeric-owner -C "$stage" -cf - "${files[@]}" | gzip -n >"$out"
fi
echo "wrote $out"
tar -tzf "$out"
