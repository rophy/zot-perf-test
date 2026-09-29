#!/usr/bin/env bash
# Run the warm-throughput suite on this host for zot pinned to 1/2/3 physical P-cores,
# over plain HTTP and TLS. Requires bench/local/setup.sh first.
# Env: CORES (default "1 2 3"), MODES (default "http tls"), plus run-suite knobs
#      (CLASSES, LADDER, REPEATS, DURATION, GAP). Results: results/<ts>-local-<mode>-<n>c/
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
CORES="${CORES:-1 2 3}"
MODES="${MODES:-http tls}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
COMPOSE="docker compose -f bench/local/compose.yaml"
UID_GID="$(id -u):$(id -g)"; export UID_GID

# P-cores are CPU pairs (0,1) (2,3) ... (10,11); E-cores 12-15. zot takes pairs from CPU 4 up.
zot_cpus() { case $1 in 1) echo "4,5";; 2) echo "4-7";; 3) echo "4-9";; esac; }
k6_cpus()  { case $1 in 1) echo "0-3,6-15";; 2) echo "0-3,8-15";; 3) echo "0-3,10-15";; esac; }
regex()    { python3 -c 'import sys
out=[]
for part in sys.argv[1].split(","):
    a,_,b=part.partition("-"); out+=range(int(a),int(b or a)+1)
print("|".join(map(str,out)))' "$1"; }

for mode in $MODES; do
  for n in $CORES; do
    zc="$(zot_cpus "$n")"; kc="$(k6_cpus "$n")"
    scheme=http; [[ $mode == tls ]] && scheme=https
    echo "##### mode=$mode cores=$n zot_cpus=$zc k6_cpus=$kc start $(date -u +%T)"
    ZOT_CPUSET="$zc" ZOT_GOMAXPROCS="$((n * 2))" ZOT_CONFIG="config-$mode.json" $COMPOSE up -d zot >/dev/null 2>&1
    for _ in $(seq 1 60); do curl -skf -o /dev/null "$scheme://localhost:15100/v2/" && break; sleep 1; done

    R="results/$TS-local-$mode-${n}c"
    export RESULTS="$R" PROM_URL=http://localhost:19190 NIC_GBPS=100000 DISKWARM_CLASS=
    export IMAGES=bench/local/generated/images.json REGISTRY="$scheme://zot:5000"
    # shellcheck disable=SC2089,SC2090  # literal quotes are PromQL label syntax
    ZOT_CPU_SELECTOR="role=\"host\",cpu=~\"$(regex "$zc")\""
    # shellcheck disable=SC2089
    CLIENT_CPU_SELECTOR="role=\"host\",cpu=~\"$(regex "$kc")\""
    # shellcheck disable=SC2090
    export ZOT_CPU_SELECTOR CLIENT_CPU_SELECTOR
    export K6_RUN="K6_CPUSET=$kc $COMPOSE run --rm -T k6"
    export PUSH_FILES="rm -f bench/local/generated/k6out/*"
    export FETCH_RESULTS="cp bench/local/generated/k6out/* \"\$RESULTS\"/"
    export DROP_CACHES_CMD=true
    scripts/run-suite.sh 2>&1 | grep --line-buffered -E "^===|stepcheck|results in" | sed -u -E "s/ stats=.*//"

    jq -n --arg label "local $mode, zot on $n P-core(s)" --arg zot_cpus "$zc" --arg k6_cpus "$kc" \
      --arg zot_version "$($COMPOSE exec -T zot zot-linux-amd64 --version 2>&1 | head -1 | jq -r .commit 2>/dev/null)" \
      --arg zot_instance_type "$(lscpu | sed -n 's/^Model name: *//p') (zot cpus $zc, GOMAXPROCS $((n * 2)))" \
      --arg client_instance_type "same host (k6 cpus $kc)" --arg kernel "$(uname -r)" \
      --arg k6_version "$($COMPOSE run --rm -T k6 'k6 version' 2>/dev/null | head -1)" \
      --argjson images "$(cat "$IMAGES")" '$ARGS.named' > "$R/env.json"
    python3 scripts/report.py "$R" >/dev/null
    echo "##### mode=$mode cores=$n done $(date -u +%T)"
  done
done
echo "CAMPAIGN DONE $TS"
