#!/usr/bin/env bash
# Local end-to-end: stack up, seed, warm up, run a tiny suite, generate report.
# Host ports: zot 15000, upstream 15001, prometheus 19090 (avoid common 5000/9090).
set -euo pipefail
cd "$(dirname "$0")/../.."
UPSTREAM_URL=http://upstream:5000 TLS_VERIFY=false zot/render-config.sh > test/local/zot-config.json
docker compose -f test/local/compose.yaml up -d
sleep 3
test/local/seed.sh
BLOB_CHECK="docker run --rm -v ccdn-local_zot-data:/var/lib/zot alpine" \
  scripts/warmup.sh localhost:15000 test/local/images.json

rm -rf test/local/results
mkdir -p test/local/results/k6out
export RESULTS=test/local/results/run
export PROM_URL=http://localhost:19090
export IMAGES=test/local/images.json
export REGISTRY=http://zot:5000
# Load host = a k6 container; /tmp/ccdn-results inside it maps to test/local/results/k6out.
uid="$(id -u)"
export K6_RUN="docker run --rm --network ccdn-local_default -u $uid \
  -v $PWD/k6:/w/k6 -v $PWD/test/local/images.json:/w/images.json -v $PWD/test/local/results/k6out:/tmp/ccdn-results \
  -e K6_PROMETHEUS_RW_SERVER_URL=http://prometheus:9090/api/v1/write \
  -e 'K6_PROMETHEUS_RW_TREND_STATS=p(50),p(95),p(99),max' \
  -w /w/k6 --entrypoint sh grafana/k6:2.3.0 -c"
export PUSH_FILES=true
export FETCH_RESULTS="cp test/local/results/k6out/* \"\$RESULTS\"/"
export DROP_CACHES_CMD=true
export CLASSES="10MB 1GB" LADDER="1 2" REPEATS=1 DURATION=25s GAP=2 MIXED_VUS=2 DISKWARM_CLASS=1GB
scripts/run-suite.sh
