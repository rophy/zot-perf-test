#!/usr/bin/env bash
# Pull every image once through zot (triggers on-demand sync) and verify all blobs are on disk.
# WARM_EXEC: prefix that runs a shell command string where the pulls should happen
#   (default: locally). On EC2 use the client node, e.g. "ssh -F terraform/app/ssh_config client",
#   so 1GB pulls don't cross an ssh tunnel to the operator machine.
set -euo pipefail
REG="${1:?zot registry host:port as reachable from WARM_EXEC}"; IMAGES="${2:?images.json}"
ZOT_ROOT="${ZOT_ROOT:-/var/lib/zot}"
WARM_EXEC="${WARM_EXEC:-bash -c}"
: "${BLOB_CHECK:?BLOB_CHECK command prefix required, e.g. 'ssh -F terraform/app/ssh_config zot sudo'}"

missing=0
while read -r repo digest; do
  echo "warmup: $repo@$digest"
  ref="$REG/$repo@$digest"
  # </dev/null everywhere: an ssh prefix would otherwise consume the image list on stdin.
  # shellcheck disable=SC2016,SC2086  # $d expands where WARM_EXEC runs; WARM_EXEC is a command prefix
  $WARM_EXEC 'd=$(mktemp -d); crane pull --insecure --format oci '"$ref"' "$d/img" >/dev/null; rc=$?; rm -rf "$d"; exit $rc' </dev/null
  # shellcheck disable=SC2086
  manifest="$($WARM_EXEC "crane manifest --insecure $ref" </dev/null)"
  for d in "$digest" $(jq -r '.config.digest, .layers[].digest' <<<"$manifest"); do
    path="$ZOT_ROOT/$repo/blobs/sha256/${d#sha256:}"
    # shellcheck disable=SC2086  # BLOB_CHECK is an intentional command prefix
    if ! $BLOB_CHECK test -s "$path" </dev/null; then
      echo "MISSING on zot disk: $path" >&2; missing=$((missing + 1))
    fi
  done
done < <(jq -r '.images[] | "\(.repo) \(.digest)"' "$IMAGES")

if (( missing > 0 )); then echo "warmup: $missing blobs missing" >&2; exit 1; fi
echo "warmup: all images cached"
