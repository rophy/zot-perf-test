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

QUERIES = {
    "zot_cpu_pct": '100 * (1 - avg(rate(node_cpu_seconds_total{role="zot",mode="idle"}[15s])))',
    "zot_proc_cores": 'rate(process_cpu_seconds_total{job="zot"}[15s])',
    "zot_rss_mb": 'process_resident_memory_bytes{job="zot"} / 1e6',
    "zot_nic_tx_gbps": 'sum(rate(node_network_transmit_bytes_total{role="zot",device!="lo"}[15s])) * 8 / 1e9',
    "zot_disk_read_mbps": 'sum(rate(node_disk_read_bytes_total{role="zot"}[15s])) / 1e6',
    "client_cpu_pct": '100 * (1 - avg(rate(node_cpu_seconds_total{role="client",mode="idle"}[15s])))',
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
