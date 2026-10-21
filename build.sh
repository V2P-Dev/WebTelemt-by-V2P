#!/usr/bin/env bash
# Bundle src/install.sh + decoys/ into a single self-contained installer.
set -Eeuo pipefail
cd "$(dirname "$0")"

src=src/install.sh
out=webproxy-install.sh

bash -n "$src"
[ "$(tail -n 1 "$src")" = "__PAYLOAD_BELOW__" ] || { echo "last line of $src must be __PAYLOAD_BELOW__" >&2; exit 1; }
for n in 1 2 3; do
  for f in meta index.html style.css; do
    [ -f "decoys/$n/$f" ] || { echo "missing decoys/$n/$f" >&2; exit 1; }
  done
done

{
  cat "$src"
  tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='2026-01-01' -czf - decoys | base64 -w 76
} > "$out"
chmod 0755 "$out"
# Sanity check: the payload must decode back into the decoy tree.
sed -n '/^__PAYLOAD_BELOW__$/,$p' "$out" | tail -n +2 | base64 -d | tar -tzf - | grep -q 'decoys/3/index.html'
echo "built $out ($(wc -c < "$out") bytes)"
