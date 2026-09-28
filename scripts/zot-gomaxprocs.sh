#!/usr/bin/env bash
# Set (or clear) GOMAXPROCS for the zot systemd service and restart it. Run on the zot node.
# Usage: sudo zot-gomaxprocs.sh <N|default>
set -euo pipefail
N="${1:?N or default}"
dropin=/etc/systemd/system/zot.service.d/gomaxprocs.conf
if [[ $N == default ]]; then
  rm -f "$dropin"
else
  mkdir -p "$(dirname "$dropin")"
  printf '[Service]\nEnvironment=GOMAXPROCS=%s\n' "$N" > "$dropin"
fi
systemctl daemon-reload
systemctl restart zot
for _ in $(seq 1 60); do curl -sf -o /dev/null localhost:5000/v2/ && break; sleep 1; done
curl -s localhost:5000/metrics | grep '^go_sched_gomaxprocs_threads'
