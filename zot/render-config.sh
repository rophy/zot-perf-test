#!/usr/bin/env bash
# Render zot config.json for a pull-through cache. Output to stdout.
set -euo pipefail
: "${UPSTREAM_URL:?UPSTREAM_URL is required}"
ROOT_DIR="${ROOT_DIR:-/var/lib/zot}"
PORT="${PORT:-5000}"
TLS_VERIFY="${TLS_VERIFY:-true}"
CREDENTIAL_HELPER="${CREDENTIAL_HELPER:-}"

jq -n \
  --arg root "$ROOT_DIR" --arg port "$PORT" --arg url "$UPSTREAM_URL" \
  --argjson tls "$TLS_VERIFY" --arg helper "$CREDENTIAL_HELPER" '
{
  distSpecVersion: "1.1.1",
  storage: { rootDirectory: $root, dedupe: false, gc: false },
  http: { address: "0.0.0.0", port: $port, compat: ["docker2s2"] },
  log: { level: "info" },
  extensions: {
    metrics: { enable: true, prometheus: { path: "/metrics" } },
    sync: {
      enable: true,
      downloadDir: ($root + "/.sync-download"),
      registries: [
        ({ urls: [$url], onDemand: true, tlsVerify: $tls, preserveDigest: true,
           maxRetries: 3, retryDelay: "10s" }
         + (if $helper == "" then {} else { credentialHelper: $helper } end))
      ]
    }
  }
}'
