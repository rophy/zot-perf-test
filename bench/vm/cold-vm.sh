#!/usr/bin/env bash
# Control the bench VM for cold-pull steps.
#   prepare  - stop every registry, disable container auto-restart, snapshot the VM as cold-base
#   restore  - restore cold-base (registry caches back to the snapshot) and boot
#   start R  - start registry R (zot|distribution|harbor), stop the others, wait until healthy, print its URL
set -euo pipefail
VM="${VM:-ccdn-bench}" SNAP=cold-base HARBOR=/opt/harbor/docker-compose.yml
vmexec() { multipass exec "$VM" -- sudo "$@"; }
vm_ip() { multipass info "$VM" --format json | jq -r ".info[\"$VM\"].ipv4[0]"; }
wait_url() {  # url [jq filter that must print true] [tries, default 90 x 2 s]
  for _ in $(seq 1 "${3:-90}"); do
    if out=$(curl -fsS -m 3 "$1" 2>/dev/null) && { [[ -z ${2:-} ]] || [[ $(jq -r "$2" <<<"$out") == true ]]; }; then return 0; fi
    sleep 2
  done
  echo "timeout waiting for $1" >&2; return 1
}
stop() {
  case "$1" in
    zot) vmexec docker stop zot >/dev/null ;;
    distribution) vmexec docker stop dist-proxy >/dev/null ;;
    harbor) vmexec docker compose -f "$HARBOR" stop >/dev/null 2>&1 ;;
  esac
}

case "${1:?prepare|restore|start}" in
  prepare)
    for r in zot distribution harbor; do stop "$r"; done
    vmexec sh -c 'docker update --restart=no $(docker ps -aq) >/dev/null && sync'
    multipass stop "$VM"
    multipass snapshot --name "$SNAP" "$VM"
    multipass start "$VM"
    wait_url "http://$(vm_ip):9100/metrics"
    ;;
  restore)
    multipass stop "$VM"
    multipass restore --destructive "$VM.$SNAP"
    multipass start "$VM"
    wait_url "http://$(vm_ip):9100/metrics"
    ;;
  start)
    reg="${2:?zot|distribution|harbor}" ip="$(vm_ip)"
    for r in zot distribution harbor; do [[ $r == "$reg" ]] || stop "$r"; done
    case "$reg" in
      zot) vmexec docker start zot >/dev/null; url="http://$ip:5000"; wait_url "$url/v2/" ;;
      distribution) vmexec docker start dist-proxy >/dev/null; url="http://$ip:5002"; wait_url "$url/v2/" ;;
      harbor) url="http://$ip"
              # restart=no containers start in no fixed order: jobservice can panic if core is not up yet,
              # so re-issue `start` (a no-op for running containers) until Harbor reports healthy.
              for _ in 1 2 3 4; do
                vmexec docker compose -f "$HARBOR" start >/dev/null 2>&1
                wait_url "$url/api/v2.0/health" '.status == "healthy"' 20 && break
              done
              wait_url "$url/api/v2.0/health" '.status == "healthy"' ;;
      *) echo "unknown registry $reg" >&2; exit 2 ;;
    esac
    echo "$url"
    ;;
esac
