#!/usr/bin/env bash
# Prepare the single-host bench: zot configs (plain + TLS), self-signed cert, stack up,
# the 6 benchmark images copied into the local upstream (same digests), warm-up through zot.
set -euo pipefail
cd "$(dirname "$0")"
G=generated
mkdir -p "$G/k6out"

if [[ ! -f $G/tls.key ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=zot" \
    -addext "subjectAltName=DNS:zot,DNS:localhost" -keyout "$G/tls.key" -out "$G/tls.crt" 2>/dev/null
  chmod 644 "$G/tls.key"   # read by the zot container user; throwaway self-signed key
fi
UPSTREAM_URL=http://upstream:5000 TLS_VERIFY=false ../../zot/render-config.sh > "$G/config-http.json"
UPSTREAM_URL=http://upstream:5000 TLS_VERIFY=false TLS_CERT=/etc/zot/tls.crt TLS_KEY=/etc/zot/tls.key \
  ../../zot/render-config.sh > "$G/config-tls.json"

UID_GID="$(id -u):$(id -g)" docker compose up -d
for _ in $(seq 1 30); do curl -sf -o /dev/null localhost:15101/v2/ && curl -sf -o /dev/null localhost:15100/v2/ && break; sleep 1; done

# Same pinned linux/amd64 digests as images/images.txt resolves today.
grep -vE '^\s*(#|$)' ../../images/images.txt | while read -r _ src repo; do
  digest="$(crane digest --platform linux/amd64 "$src")"
  if ! crane manifest --insecure "localhost:15101/$repo@$digest" >/dev/null 2>&1; then
    echo "copy $src@$digest -> upstream/$repo:bench"
    crane copy --platform linux/amd64 "$src@$digest" "localhost:15101/$repo:bench" --insecure
  fi
done
python3 ../../images/describe.py --registry localhost:15101 --insecure --tag bench ../../images/images.txt > "$G/images.json"

BLOB_CHECK="docker run --rm -v ccdn-bench_zot-data:/var/lib/zot alpine" \
  ../../scripts/warmup.sh localhost:15100 "$G/images.json"
