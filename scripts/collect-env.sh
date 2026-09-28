#!/usr/bin/env bash
# Print env.json describing the benchmark environment.
set -euo pipefail
: "${ZOT_EXEC:?}" "${CLIENT_EXEC:?}" "${IMAGES:?}"
# ZOT_EXEC / CLIENT_EXEC are ssh prefixes: a single string argument is run by the remote shell.
# shellcheck disable=SC2016  # expanded remotely
imds='TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60"); curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type'
jq -n \
  --arg zot_version "$($ZOT_EXEC /usr/local/bin/zot --version 2>&1 | head -1 | jq -r .commit 2>/dev/null || echo n/a)" \
  --arg zot_config_sha256 "$($ZOT_EXEC sudo sha256sum /etc/zot/config.json | cut -d' ' -f1)" \
  --arg zot_instance_type "$($ZOT_EXEC "$imds" 2>/dev/null || echo n/a)" \
  --arg client_instance_type "$($CLIENT_EXEC "$imds" 2>/dev/null || echo n/a)" \
  --arg kernel "$($ZOT_EXEC uname -r)" \
  --arg k6_version "$($CLIENT_EXEC k6 version | head -1)" \
  --argjson images "$(cat "$IMAGES")" \
  '$ARGS.named'
