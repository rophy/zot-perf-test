#!/usr/bin/env bash
# Run ONE cold-pull step against a registry in the bench VM and append a row to results/cold-steps.md.
# Usage: bench/vm/cold-step.sh <zot|distribution|harbor> <unique|stampede> <class> <vus> [image-index]
# Env: RESTORE=1|0 (default 1 for unique, 0 for stampede) restores snapshot cold-base first;
#      POOL_LIMIT=n pulls only the first n images of the class (smoke runs).
set -euo pipefail
cd "$(dirname "$0")/../.."
reg="$1" scen="$2" cls="$3" vus="$4" idx="${5:-0}" limit="${POOL_LIMIT:-0}"
restore="${RESTORE:-$([[ $scen == unique ]] && echo 1 || echo 0)}"
free_gb=$(df --output=avail -BG / | tail -1 | tr -dc 0-9)
(( free_gb >= 20 )) || { echo "host disk free ${free_gb}G < 20G; stop" >&2; exit 1; }

[[ $restore == 1 ]] && bench/vm/cold-vm.sh restore
url="$(bench/vm/cold-vm.sh start "$reg")"
# Settle: wait (max 180 s) until boot/registry start-up work is done (VM busy < 0.3 cores over 15 s).
for _ in $(seq 1 36); do
  busy=$(curl -fsS http://localhost:19190/api/v1/query --data-urlencode \
    'query=sum(rate(node_cpu_seconds_total{role="vm",mode!~"idle|steal"}[15s]))' | jq -r '.data.result[0].value[1] // "9"')
  awk -v b="$busy" 'BEGIN{exit !(b < 0.3)}' && break
  sleep 5
done

R="results/$(date -u +%Y%m%dT%H%M%SZ)-cold-$reg-$scen-$cls-v$vus"
mkdir -p "$R" bench/vm/generated/k6out
images_file="cold-$reg.json" prefix=""
[[ $reg == harbor ]] && prefix="proxy/"
jq --arg p "$prefix" '.images |= map(.repo = $p + .repo)' images/cold.json > "bench/vm/generated/$images_file"
rm -f bench/vm/generated/k6out/*
export UID_GID="$(id -u):$(id -g)" IMAGES_FILE="$images_file"
k6() {  # summary-file [extra -e args...]
  local out="$1"; shift
  docker compose -f bench/vm/compose.yaml run --rm -T k6 \
    "k6 run --quiet --summary-export /tmp/ccdn-results/$out -e REGISTRY=$url -e IMAGES=../images.json \
     -e CLASS=$cls -e IMAGE_INDEX=$idx -e POOL_LIMIT=$limit $*"
}

t0=$(date +%s)
set +e
k6 summary.json -e SCENARIO="$scen" -e VUS="$vus" cold.js > "$R/k6.log" 2>&1
rc=$?
set -e
t1=$(date +%s)
cp bench/vm/generated/k6out/summary.json "$R/" 2>/dev/null || true
python3 scripts/coldstep.py collect --registry "$reg" --scenario "$scen" --class "$cls" --vus "$vus" \
  --image-index "$idx" --pool-limit "$limit" --images "bench/vm/generated/$images_file" \
  --start "$t0" --k6-end "$t1" --k6-exit "$rc" --run-dir "$R"

integrity=-
if [[ $scen == stampede ]]; then   # pull once more with the upstream stopped: must be fully cached
  docker stop ccdn-bench-upstream-1 >/dev/null
  k6 verify.json -e SCENARIO=stampede -e VUS=1 cold.js > "$R/k6-verify.log" 2>&1 || true
  docker start ccdn-bench-upstream-1 >/dev/null
  cp bench/vm/generated/k6out/verify.json "$R/" 2>/dev/null || true
  integrity=$(jq -r 'if (.metrics.image_pulls.count // 0) == 1 then "ok" else "FAIL" end' "$R/verify.json" 2>/dev/null || echo FAIL)
fi
python3 scripts/coldstep.py append --row "$R/row.json" --integrity "$integrity" --log results/cold-steps.md
