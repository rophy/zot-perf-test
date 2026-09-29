#!/usr/bin/env bash
# Run the warm-throughput suite on this host with zot pinned to given CPU sets,
# over plain HTTP and TLS. Requires bench/local/setup.sh first.
# Env: ZOT_CPUSETS (space-separated cpusets, default "4"; e.g. "4 4,6 4,6,8"),
#      MODES (default "http tls"), plus run-suite knobs (CLASSES, LADDER, REPEATS, DURATION, GAP).
# zot GOMAXPROCS = number of CPUs in its set. k6 gets every CPU whose physical core zot
# does not touch (a zot thread's hyperthread sibling stays idle).
# Results: results/<ts>-local-<mode>-cpu<set>/
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
ZOT_CPUSETS="${ZOT_CPUSETS:-4}"
MODES="${MODES:-http tls}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
COMPOSE="docker compose -f bench/local/compose.yaml"
UID_GID="$(id -u):$(id -g)"; export UID_GID

# CPU list helpers. P-cores are sibling pairs (0,1) (2,3) ... (10,11); E-cores 12-15.
expand() { python3 -c 'import sys
out=[]
for part in sys.argv[1].split(","):
    a,_,b=part.partition("-"); out+=range(int(a),int(b or a)+1)
print(" ".join(map(str,out)))' "$1"; }
k6_cpus() { python3 -c 'import sys
zot={int(c) for c in sys.argv[1].split()}
busy={c - c % 2 for c in zot if c < 12} | {c - c % 2 + 1 for c in zot if c < 12} | zot
print(",".join(str(c) for c in range(16) if c not in busy))' "$1"; }
regex() { tr ' ' '|' <<<"$1"; }

for mode in $MODES; do
  for zc in $ZOT_CPUSETS; do
    zl="$(expand "$zc")"; n="$(wc -w <<<"$zl")"; kc="$(k6_cpus "$zl")"
    scheme=http; [[ $mode == tls ]] && scheme=https
    echo "##### mode=$mode zot_cpus=$zc threads=$n k6_cpus=$kc start $(date -u +%T)"
    ZOT_CPUSET="$zc" ZOT_GOMAXPROCS="$n" ZOT_CONFIG="config-$mode.json" $COMPOSE up -d zot >/dev/null 2>&1
    for _ in $(seq 1 60); do curl -skf -o /dev/null "$scheme://localhost:15100/v2/" && break; sleep 1; done

    R="results/$TS-local-$mode-cpu${zc//,/_}"
    export RESULTS="$R" PROM_URL=http://localhost:19190 NIC_GBPS=100000 DISKWARM_CLASS=
    export IMAGES=bench/local/generated/images.json REGISTRY="$scheme://zot:5000"
    # shellcheck disable=SC2089,SC2090  # literal quotes are PromQL label syntax
    ZOT_CPU_SELECTOR="role=\"host\",cpu=~\"$(regex "$zl")\""
    # shellcheck disable=SC2089
    CLIENT_CPU_SELECTOR="role=\"host\",cpu=~\"$(regex "$(expand "$kc")")\""
    # shellcheck disable=SC2090
    export ZOT_CPU_SELECTOR CLIENT_CPU_SELECTOR
    # zot egress = receive on zot's host-side veth (found via zot's eth0 iflink).
    idx="$(docker run --rm --net container:ccdn-bench-zot-1 alpine cat /sys/class/net/eth0/iflink)"
    veth="$(grep -lx "$idx" /sys/class/net/veth*/ifindex | cut -d/ -f5)"
    export ZOT_NET_QUERY="sum(rate(node_network_receive_bytes_total{role=\"host\",device=\"$veth\"}[15s]))"
    export DISK_SELECTOR='role="host",device="nvme0n1"'
    export K6_RUN="K6_CPUSET=$kc $COMPOSE run --rm -T k6"
    export PUSH_FILES="rm -f bench/local/generated/k6out/*"
    export FETCH_RESULTS="cp bench/local/generated/k6out/* \"\$RESULTS\"/"
    export DROP_CACHES_CMD=true
    scripts/run-suite.sh 2>&1 | grep --line-buffered -E "^===|stepcheck|results in" | sed -u -E "s/ stats=.*//"

    jq -n --arg label "local $mode, zot on cpus $zc ($n thread(s))" --arg zot_cpus "$zc" --arg k6_cpus "$kc" \
      --arg zot_version "$($COMPOSE exec -T zot zot-linux-amd64 --version 2>&1 | head -1 | jq -r .commit 2>/dev/null)" \
      --arg zot_instance_type "$(lscpu | sed -n 's/^Model name: *//p') (zot cpus $zc, GOMAXPROCS $n)" \
      --arg client_instance_type "same host (k6 cpus $kc)" --arg kernel "$(uname -r)" \
      --arg k6_version "$($COMPOSE run --rm -T k6 'k6 version' 2>/dev/null | head -1)" \
      --argjson images "$(cat "$IMAGES")" '$ARGS.named' > "$R/env.json"
    python3 scripts/report.py "$R" >/dev/null
    echo "##### mode=$mode zot_cpus=$zc done $(date -u +%T)"
  done
done
echo "CAMPAIGN DONE $TS"
