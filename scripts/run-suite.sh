#!/usr/bin/env bash
# Run the warm-throughput suite: classes × concurrency ladder × repeats (+ mixed, + disk-warm).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
: "${IMAGES:?}" "${REGISTRY:?}" "${K6_RUN:?}" "${PUSH_FILES:?}" "${FETCH_RESULTS:?}" "${DROP_CACHES_CMD:?}"
RESULTS="${RESULTS:-results/$(date -u +%Y%m%dT%H%M%SZ)}"
CLASSES="${CLASSES-10MB 100MB 1GB}"
LADDER="${LADDER:-1 4 16 64 128 256}"
REPEATS="${REPEATS:-3}"
DURATION="${DURATION:-60s}"
GAP="${GAP:-10}"
MIXED_VUS="${MIXED_VUS:-}"
DISKWARM_CLASS="${DISKWARM_CLASS-1GB}"
export RESULTS

mkdir -p "$RESULTS"
cp "$IMAGES" "$RESULTS/images.json"
echo "run_id,class,vus,repeat,start_epoch,end_epoch,exit_code,drop_caches" > "$RESULTS/steps.csv"
eval "$PUSH_FILES" || { echo "PUSH_FILES failed" >&2; exit 1; }

run_step() { # class vus repeat drop_caches -> returns stepcheck exit code
  local cls="$1" vus="$2" rep="$3" dc="$4"
  local run_id="${cls}-v${vus}-r${rep}"
  [[ $dc == 1 ]] && run_id+="-dc"
  if [[ $dc == 1 ]]; then eval "$DROP_CACHES_CMD" || echo "WARN: drop caches failed" >&2; fi
  echo "=== $run_id"
  local cmd="env K6_WEB_DASHBOARD_EXPORT=/tmp/ccdn-results/$run_id.html K6_WEB_DASHBOARD_PORT=-1"
  cmd+=" k6 run -q --out web-dashboard --out experimental-prometheus-rw"
  cmd+=" --summary-export /tmp/ccdn-results/$run_id.summary.json"
  cmd+=" -e REGISTRY=$REGISTRY -e IMAGES=../images.json -e CLASS=$cls -e VUS=$vus -e DURATION=$DURATION"
  cmd+=" --tag run_id=$run_id pull.js > /tmp/ccdn-results/$run_id.log 2>&1"
  local start end rc
  start=$(date +%s)
  # eval strips the %q layer, so $cmd reaches K6_RUN as ONE argument:
  # `ssh host 'cd dir &&' "$cmd"` (ssh joins args into one remote shell line) and `sh -c "$cmd"` both work.
  eval "$K6_RUN $(printf '%q' "$cmd")"
  rc=$?
  end=$(date +%s)
  echo "$run_id,$cls,$vus,$rep,$start,$end,$rc,$dc" >> "$RESULTS/steps.csv"
  sleep "$GAP"
  python3 scripts/stepcheck.py "$RESULTS" "$run_id"
}

for rep in $(seq 1 "$REPEATS"); do
  for cls in $CLASSES; do
    for vus in $LADDER; do
      run_step "$cls" "$vus" "$rep" 0; rc=$?
      if [[ $rc == 3 ]]; then echo "--- $cls r$rep: ladder stopped at $vus VUs"; break; fi
    done
  done
  if [[ -n $MIXED_VUS ]]; then run_step mixed "$MIXED_VUS" "$rep" 0; fi
done

if [[ -n $DISKWARM_CLASS ]]; then
  for vus in $LADDER; do
    run_step "$DISKWARM_CLASS" "$vus" 1 1; rc=$?
    [[ $rc == 3 ]] && break
  done
fi

eval "$FETCH_RESULTS"
python3 scripts/report.py "$RESULTS"
echo "results in $RESULTS"
