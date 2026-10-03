#!/usr/bin/env bash
# Run ONE load step against a registry in the bench VM and append a row to results/vm-steps.md.
# Usage: bench/vm/step.sh <label, e.g. harbor> <registry URL, e.g. http://VM_IP> <10MB|100MB|1GB|mixed> <vus> [duration]
# Registry CPU/memory = whole VM (all vCPUs / used memory), so every component is counted.
set -euo pipefail
cd "$(dirname "$0")/../.."
label="$1" reg="$2" cls="$3" vus="$4" dur="${5:-40s}"
vm_vcpus="${VM_VCPUS:-4}"
log=results/vm-steps.md
mkdir -p bench/vm/generated/k6out results

UID_GID="$(id -u):$(id -g)"; export UID_GID
RESULTS="results/$(date -u +%Y%m%dT%H%M%SZ)-vm-$label"; export RESULTS
export PROM_URL=http://localhost:19190 NIC_GBPS=100000 DISKWARM_CLASS="" CLASSES="$cls" LADDER="$vus" REPEATS=1 DURATION="$dur" GAP=2
export IMAGES="bench/vm/generated/${IMAGES_FILE:-images-harbor.json}" REGISTRY="$reg"
export ZOT_CPU_SELECTOR='role="vm"'
export CLIENT_CPU_SELECTOR='role="host"'
export PROC_CORES_QUERY='sum(rate(node_cpu_seconds_total{role="vm",mode!~"idle|steal"}[15s]))'
export RSS_QUERY='(node_memory_MemTotal_bytes{role="vm"} - node_memory_MemAvailable_bytes{role="vm"}) / 1e6'
export ZOT_NET_QUERY='sum(rate(node_network_transmit_bytes_total{role="vm",device="ens3"}[15s]))'
export DISK_SELECTOR='role="vm",device="sda"'
export K6_RUN="docker compose -f bench/vm/compose.yaml run --rm -T k6"
export PUSH_FILES="rm -f bench/vm/generated/k6out/*"
export FETCH_RESULTS="cp bench/vm/generated/k6out/* \"\$RESULTS\"/"
export DROP_CACHES_CMD=true
out="$(scripts/run-suite.sh 2>&1)"
[[ -f $RESULTS/rows.json ]] || { echo "step failed:"; echo "$out" | tail -20; exit 1; }

if [[ ! -f $log ]]; then
  cat > "$log" <<'HDR'
# VM runs (temporary)

VM: multipass, Ubuntu 24.04, 4 vCPU (unpinned), 8 GiB. k6 on the host. Registry CPU = busy vCPUs of the whole VM; memory = VM used memory (total - available). Stats = steady-state averages.

| time (UTC) | registry | class | VUs | MB/s | Gbps | pulls/s | p50 ms | p99 ms | fail % | VM cores busy / vCPUs | VM mem used MB | VM net tx Gbps | disk rd IOPS | disk wr IOPS | host CPU % | run dir |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
HDR
fi
jq -r --arg l "$label" --arg v "$vm_vcpus" --arg t "$(date -u +%H:%M)" --arg d "$RESULTS" '
  def r(x; p): if x == null then "n/a" else ((x * pow(10; p) | round) / pow(10; p) | tostring) end;
  .[] | "| \($t) | \($l) | \(.class) | \(.vus) | \(r(.mb_per_s;0)) | \(r(.mb_per_s*8/1000;1)) | \(r(.pulls_per_s;1)) | \(r(.p50_ms;0)) | \(r(.p99_ms;0)) | \(r(.fail_rate*100;2)) | \(r(.zot_proc_cores;2)) / \($v) | \(r(.zot_rss_mb;0)) | \(r(.zot_nic_tx_gbps;1)) | \(r(.disk_read_iops;0)) | \(r(.disk_write_iops;0)) | \(r(.client_cpu_pct;0)) | \($d|sub("^results/";"")) |"' \
  "$RESULTS/rows.json" | tee -a "$log"
