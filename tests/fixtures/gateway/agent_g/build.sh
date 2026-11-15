#!/usr/bin/env bash
# Build infra/agents/build/source-g.tar.gz (v2 agent G) with agent.py and requirements.txt at the tarball root.
# VARIANT=unpinned (T47r, plan 3b): source-g-unpinned.tar.gz with every version pin removed, as in run 6.
# VARIANT=run6 (T47r2, plan 3b): source-g-run6.tar.gz with requirements-run6.txt (run-6 package set) as requirements.txt.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out_dir="$here/../../../../infra/agents/build"
mkdir -p "$out_dir"
variant="${VARIANT:-pinned}"
case "$variant" in pinned) name=source-g.tar.gz ;; unpinned) name=source-g-unpinned.tar.gz ;; run6) name=source-g-run6.tar.gz ;; *) echo "VARIANT pinned|unpinned|run6" >&2; exit 2 ;; esac
out="$(cd "$out_dir" && pwd)/$name"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

files=(agent.py requirements.txt)
for f in "${files[@]}"; do
  cp "$here/$f" "$stage/$f"
  touch -t 202001010000 "$stage/$f"
done
if [[ "$variant" == run6 ]]; then
  grep -vE '^[[:space:]]*(#|$)' "$here/requirements-run6.txt" >"$stage/requirements.txt"
  touch -t 202001010000 "$stage/requirements.txt"
fi
if [[ "$variant" == unpinned ]]; then
  sed -E -e 's/[[:space:]]*#.*$//' -e 's/[=<>~!]=.*$//' -e '/^[[:space:]]*$/d' "$here/requirements.txt" >"$stage/requirements.txt"
  touch -t 202001010000 "$stage/requirements.txt"
fi

# Prefer GNU tar for determinism (sorted, fixed mtime, numeric owner); fall back to bsdtar.
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  tar --sort=name --mtime='2020-01-01 00:00:00' --owner=0 --group=0 --numeric-owner \
    -C "$stage" -cf - "${files[@]}" | gzip -n >"$out"
else
  tar --uid 0 --gid 0 --numeric-owner -C "$stage" -cf - "${files[@]}" | gzip -n >"$out"
fi
echo "wrote $out"
tar -tzf "$out"
