#!/usr/bin/env python3
"""Collect one cold-pull step (wait until quiet, gather k6/Prometheus/upstream figures) or append it to the step log."""
import argparse
import json
import os
import subprocess
import time
import urllib.parse
import urllib.request

import coldlib as c

PROM = os.environ.get("PROM_URL", "http://localhost:19190")
UPSTREAM = os.environ.get("UPSTREAM_CONTAINER", "ccdn-bench-upstream-1")
Q_CPU = 'sum(node_cpu_seconds_total{role="vm",mode!~"idle|steal"})'
Q_DISK_BYTES = 'sum(node_disk_written_bytes_total{role="vm",device="sda"})'
Q_DISK_OPS = 'sum(node_disk_writes_completed_total{role="vm",device="sda"})'
Q_MEM = '(node_memory_MemTotal_bytes{role="vm"} - node_memory_MemAvailable_bytes{role="vm"}) / 1e6'
CAP_S = 900


def prom(q, t):
    qs = urllib.parse.urlencode({"query": q, "time": t})
    with urllib.request.urlopen(f"{PROM}/api/v1/query?{qs}", timeout=30) as r:
        res = json.load(r)["data"]["result"]
    return float(res[0]["value"][1]) if res else None


def delta(q, t0, t1):
    a, b = prom(q, t0), prom(q, t1)
    return None if a is None or b is None else b - a


def upstream_tx():
    out = subprocess.run(["docker", "exec", UPSTREAM, "cat", "/sys/class/net/eth0/statistics/tx_bytes"],
                         check=True, capture_output=True, text=True).stdout
    return int(out)


def wait_quiet(k6_end):
    samples = []
    while True:
        now = time.time()
        samples.append((now, upstream_tx(), prom(Q_DISK_BYTES, now) or 0.0))
        end = c.quiet_end(samples, k6_end)
        if end is not None:
            return end, False
        if now - k6_end > CAP_S:
            return now, True
        time.sleep(2)


def upstream_log(t0, t1):
    p = subprocess.run(["docker", "logs", "--since", str(t0), "--until", str(t1), UPSTREAM],
                       check=True, capture_output=True, text=True)
    return (p.stdout + p.stderr).splitlines(keepends=True)


def collect(a):
    end, capped = wait_quiet(a.k6_end)
    end = int(end) + 1
    window = end - a.start
    k6_s = max(a.k6_end - a.start, 15)
    try:
        with open(f"{a.run_dir}/summary.json") as f:
            summary = json.load(f)
    except FileNotFoundError:
        summary = {"metrics": {}}
    prom_d = {
        "cpu_s": delta(Q_CPU, a.start, end),
        "disk_wr_mb": (delta(Q_DISK_BYTES, a.start, end) or 0) / 1e6,
        "disk_wr_ops": delta(Q_DISK_OPS, a.start, end),
        "mem_peak_mb": prom(f"max_over_time(({Q_MEM})[{window}s:5s])", end),
        "mem_avg_mb": prom(f"avg_over_time(({Q_MEM})[{window}s:5s])", end),
        "host_cpu_pct": prom(f'100 * (1 - avg(rate(node_cpu_seconds_total{{role="host",mode="idle"}}[{k6_s}s])))',
                             a.k6_end),
    }
    lines = upstream_log(a.start, end)
    with open(f"{a.run_dir}/upstream.log", "w") as f:
        f.writelines(lines)
    with open(a.images) as f:
        images = c.select_images(json.load(f)["images"], a.cls, a.scenario, a.pool_limit, a.image_index)
    meta = {"registry": a.registry, "scenario": a.scenario, "class": a.cls, "vus": a.vus,
            "image_index": a.image_index, "start": a.start, "k6_end": a.k6_end, "end": end,
            "capped": capped, "k6_exit": a.k6_exit, "run_dir": a.run_dir}
    row = c.step_row(meta, c.k6_counts(summary), prom_d, c.parse_access_log(lines), images)
    with open(f"{a.run_dir}/row.json", "w") as f:
        json.dump(row, f, indent=2)
    print(json.dumps({k: row[k] for k in ("gb_served", "window_s", "cpu_s_per_gb", "vm_cores",
                                          "mem_peak_mb", "dedup_x", "cold_ok", "failed")}))


def append(a):
    with open(a.row) as f:
        row = {**json.load(f), "integrity": a.integrity}
    new = not os.path.exists(a.log)
    with open(a.log, "a") as f:
        if new:
            f.write(c.MD_HEADER + "\n")
        f.write(c.markdown_row(row) + "\n")
    print(c.markdown_row(row))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("collect")
    for name, typ in (("--registry", str), ("--scenario", str), ("--class", str), ("--vus", int),
                      ("--image-index", int), ("--pool-limit", int), ("--images", str), ("--start", int),
                      ("--k6-end", int), ("--k6-exit", int), ("--run-dir", str)):
        p.add_argument(name, type=typ, required=True, **({"dest": "cls"} if name == "--class" else {}))
    q = sub.add_parser("append")
    q.add_argument("--row", required=True)
    q.add_argument("--integrity", default="-")
    q.add_argument("--log", required=True)
    a = ap.parse_args()
    collect(a) if a.cmd == "collect" else append(a)


if __name__ == "__main__":
    main()
