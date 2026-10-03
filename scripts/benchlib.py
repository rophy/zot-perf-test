"""Shared helpers: k6 summaries, Prometheus queries, per-step verdicts."""
import csv
import json
import os
import urllib.parse
import urllib.request

# Measured NIC capacity (Gbps) at which the ladder stops. EC2 "up to" NICs burst above
# their baseline (m6idn.2xlarge: 12.5 baseline, ~39.7 measured burst), so set NIC_GBPS per run.
NIC_BASELINE_GBPS = float(os.environ.get("NIC_GBPS", "12.5"))
NIC_SAT = 0.95
CPU_SAT_PCT = 90.0
CLIENT_CPU_MAX_PCT = 70.0

INT_FIELDS = ("vus", "repeat", "start_epoch", "end_epoch", "exit_code", "drop_caches")

# Label selectors for node CPU. Defaults match the two-node EC2 setup; a single-host run
# selects CPU sets instead, e.g. ZOT_CPU_SELECTOR='role="host",cpu=~"4|5"'.
ZOT_SEL = os.environ.get("ZOT_CPU_SELECTOR", 'role="zot"')
CLIENT_SEL = os.environ.get("CLIENT_CPU_SELECTOR", 'role="client"')
# zot egress. Single host: zot's traffic appears as *receive* on its host-side veth.
ZOT_NET_QUERY = os.environ.get(
    "ZOT_NET_QUERY", 'sum(rate(node_network_transmit_bytes_total{role="zot",device!="lo"}[15s]))')
DISK_SEL = os.environ.get("DISK_SELECTOR", 'role="zot"')
# Registry CPU (cores) and memory (MB). Defaults: the zot process. A VM-based run can use
# whole-VM figures instead, covering every component of a multi-container registry.
PROC_CORES_QUERY = os.environ.get("PROC_CORES_QUERY", 'rate(process_cpu_seconds_total{job=~"zot.*"}[15s])')
RSS_QUERY = os.environ.get("RSS_QUERY", 'process_resident_memory_bytes{job=~"zot.*"} / 1e6')

QUERIES = {
    "zot_cpu_pct": '100 * (1 - avg(rate(node_cpu_seconds_total{%s,mode="idle"}[15s])))' % ZOT_SEL,
    "zot_proc_cores": PROC_CORES_QUERY,
    "zot_rss_mb": RSS_QUERY,
    "zot_nic_tx_gbps": "(%s) * 8 / 1e9" % ZOT_NET_QUERY,
    "zot_disk_read_mbps": 'sum(rate(node_disk_read_bytes_total{%s}[15s])) / 1e6' % DISK_SEL,
    "disk_read_iops": 'sum(rate(node_disk_reads_completed_total{%s}[15s]))' % DISK_SEL,
    "disk_write_iops": 'sum(rate(node_disk_writes_completed_total{%s}[15s]))' % DISK_SEL,
    "client_cpu_pct": '100 * (1 - avg(rate(node_cpu_seconds_total{%s,mode="idle"}[15s])))' % CLIENT_SEL,
}


def read_steps(path):
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        for k in INT_FIELDS:
            r[k] = int(r[k])
    return rows


def summarize_k6(summary):
    m = summary["metrics"]
    pulls = m.get("image_pulls", {})
    nbytes = m.get("image_pull_bytes", {})
    dur = m.get("image_pull_duration", {})
    return {
        "pulls_per_s": pulls.get("rate", 0),
        "mb_per_s": nbytes.get("rate", 0) / 1e6,
        "p50_ms": dur.get("med"),
        "p95_ms": dur.get("p(95)"),
        "p99_ms": dur.get("p(99)"),
        "max_ms": dur.get("max"),
        "fail_rate": m.get("image_pull_failed", {}).get("value", 0),
    }


def prom_avg(query_fn, promql, start, end):
    values = query_fn(promql, start, end)
    return sum(values) / len(values) if values else None


# Skip k6 start-up and the 15s rate() window ramp so averages reflect steady state.
RAMP_SKIP_S = 20


def steady_window(start, end):
    if end - start > 2 * RAMP_SKIP_S:
        return start + RAMP_SKIP_S, end
    return start + (end - start) // 2, end


def node_stats(query_fn, start, end):
    s, e = steady_window(start, end)
    return {k: prom_avg(query_fn, q, s, e) for k, q in QUERIES.items()}


def verdict(stats, exit_code):
    client = stats.get("client_cpu_pct")
    valid = client is not None and client <= CLIENT_CPU_MAX_PCT
    if client is not None and client > CLIENT_CPU_MAX_PCT:
        return "client", False
    if exit_code == 99:
        return "threshold", valid
    if (stats.get("zot_nic_tx_gbps") or 0) >= NIC_BASELINE_GBPS * NIC_SAT:
        return "zot-nic", valid
    if (stats.get("zot_cpu_pct") or 0) >= CPU_SAT_PCT:
        return "zot-cpu", valid
    return "none", valid


def http_query_fn(prom_url):
    def query(promql, start, end):
        qs = urllib.parse.urlencode({"query": promql, "start": start, "end": end, "step": 5})
        with urllib.request.urlopen(f"{prom_url}/api/v1/query_range?{qs}", timeout=30) as r:
            data = json.load(r)["data"]["result"]
        return [float(v) for series in data for _, v in series["values"]]
    return query


def load_summary(results_dir, run_id):
    try:
        with open(f"{results_dir}/{run_id}.summary.json") as f:
            return json.load(f)
    except FileNotFoundError:
        return {"metrics": {}}
