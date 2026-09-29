#!/usr/bin/env bash
# Run ONE load step and append a row to the running report results/local-steps.md.
# Usage: bench/local/step.sh <zot-cpuset, e.g. 4 | 4,6> <http|tls> <10MB|100MB|1GB|mixed> <vus> [duration]
set -euo pipefail
cd "$(dirname "$0")/../.."
zc="$1" mode="$2" cls="$3" vus="$4" dur="${5:-40s}"
log=results/local-steps.md
n="$(tr "," "\n" <<<"$zc" | wc -l)"   # threads (cpusets here are comma lists)
out="$(ZOT_CPUSETS="$zc" MODES="$mode" CLASSES="$cls" LADDER="$vus" REPEATS=1 DURATION="$dur" GAP=2 \
  bench/local/campaign.sh 2>&1)"
dir="$(sed -n 's/^results in //p' <<<"$out" | tail -1)"
[[ -n $dir && -f $dir/rows.json ]] || { echo "step failed:"; echo "$out" | tail -20; exit 1; }

mkdir -p results
if [[ ! -f $log ]]; then
  cat > "$log" <<'HDR'
# Local per-core runs (temporary)

Host: see env.json in each run dir. zot cap = number of pinned CPU threads (GOMAXPROCS = same). Stats = steady-state averages.

| time (UTC) | zot cpus | mode | class | VUs | MB/s | Gbps | pulls/s | p50 ms | p99 ms | fail % | zot cores / cap | zot RSS MB | zot net Gbps | disk rd IOPS | disk wr IOPS | disk rd MB/s | k6 CPU % | run dir |
|---|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
HDR
fi
jq -r --arg n "$n" --arg zc "$zc" --arg m "$mode" --arg t "$(date -u +%H:%M)" --arg d "$dir" '
  def r(x; p): if x == null then "n/a" else ((x * pow(10; p) | round) / pow(10; p) | tostring) end;
  .[] | "| \($t) | \($zc) | \($m) | \(.class) | \(.vus) | \(r(.mb_per_s;0)) | \(r(.mb_per_s*8/1000;1)) | \(r(.pulls_per_s;1)) | \(r(.p50_ms;0)) | \(r(.p99_ms;0)) | \(r(.fail_rate*100;2)) | \(r(.zot_proc_cores;2)) / \($n) | \(r(.zot_rss_mb;0)) | \(r(.zot_nic_tx_gbps;1)) | \(r(.disk_read_iops;0)) | \(r(.disk_write_iops;0)) | \(r(.zot_disk_read_mbps;1)) | \(r(.client_cpu_pct;0)) | \($d|sub("^results/";"")) |"' \
  "$dir/rows.json" | tee -a "$log"
