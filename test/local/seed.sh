#!/usr/bin/env bash
# Push 3 synthetic images to the local upstream registry and write images.json.
set -euo pipefail
cd "$(dirname "$0")"
UPSTREAM="${UPSTREAM:-localhost:15001}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

push_image() { # repo, total size in MiB (split over 3 layers)
  local repo="$1" mib="$2" ref="$UPSTREAM/$1:bench"
  local args=()
  for i in 1 2 3; do
    mkdir -p "$tmp/$repo/$i"
    head -c "$((mib * 1024 * 1024 / 3))" /dev/urandom > "$tmp/$repo/$i/data"
    tar -C "$tmp/$repo/$i" -cf "$tmp/$repo/$i.tar" data
    args+=(-f "$tmp/$repo/$i.tar")
  done
  crane append --insecure --platform linux/amd64 "${args[@]}" -t "$ref" >/dev/null
  echo "pushed $ref"
}

push_image bench/small 2
push_image bench/medium 8
push_image bench/large 32
python3 ../../images/describe.py --registry "$UPSTREAM" --insecure images.txt > images.json
echo "wrote test/local/images.json"
