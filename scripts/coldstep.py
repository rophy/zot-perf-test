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
Q_CPU = 'sum(node_cpu_seconds_total{role="vm",mode!~"idle|steal|iowait"})'
Q_IOWAIT = 'sum(node_cpu_seconds_total{role="vm",mode="iowait"})'
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
        disk = prom(Q_DISK_BYTES, now)
        if disk is not None:  # missing Prometheus data is never "quiet"
            samples.append((now, upstream_tx(), disk))
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


def prom_figures(start, end, k6_end):
    window = end - start
    k6_s = max(k6_end - start, 15)
    return {
        "cpu_s": delta(Q_CPU, start, end),
        "iowait_s": delta(Q_IOWAIT, start, end),
        "disk_wr_mb": None if (d := delta(Q_DISK_BYTES, start, end)) is None else d / 1e6,
        "disk_wr_ops": delta(Q_DISK_OPS, start, end),
        "mem_peak_mb": prom(f"max_over_time(({Q_MEM})[{window}s:5s])", end),
        "mem_avg_mb": prom(f"avg_over_time(({Q_MEM})[{window}s:5s])", end),
        "host_cpu_pct": prom(f'100 * (1 - avg(rate(node_cpu_seconds_total{{role="host",mode="idle"}}[{k6_s}s])))',
                             k6_end),
    }


def collect(a):
    end, capped = wait_quiet(a.k6_end)
    end = int(end) + 1
    summary_missing = False
    try:
        with open(f"{a.run_dir}/summary.json") as f:
            summary = json.load(f)
    except FileNotFoundError:
        summary, summary_missing = {"metrics": {}}, True
    prom_d = prom_figures(a.start, end, a.k6_end)
    lines = upstream_log(a.start, end)
    with open(f"{a.run_dir}/upstream.log", "w") as f:
        f.writelines(lines)
    with open(a.images) as f:
        images = c.select_images(json.load(f)["images"], a.cls, a.scenario, a.pool_limit, a.image_index)
    meta = {"registry": a.registry, "scenario": a.scenario, "class": a.cls, "vus": a.vus,
            "image_index": a.image_index, "start": a.start, "k6_end": a.k6_end, "end": end,
            "capped": capped, "k6_exit": a.k6_exit, "summary_missing": summary_missing, "run_dir": a.run_dir,
            "pool_limit": a.pool_limit}
    row = c.step_row(meta, c.k6_counts(summary), prom_d, c.parse_access_log(lines), images)
    with open(f"{a.run_dir}/row.json", "w") as f:
        json.dump(row, f, indent=2)
    print(json.dumps({k: row[k] for k in ("gb_served", "window_s", "cpu_s_per_gb", "vm_cores",
                                          "mem_peak_mb", "dedup_x", "cold_ok", "failed")}))


META_KEYS = ("registry", "scenario", "class", "vus", "image_index", "start", "k6_end", "end", "capped", "k6_exit",
             "summary_missing", "run_dir", "pool_limit")
UP_KEYS = ("blob_gets", "blob_bytes", "blob_heads", "manifest_gets", "manifest_heads")


def recompute(a):
    rows = []
    for d in a.run_dirs:
        path = f"{d}/row.json"
        if not os.path.exists(path):
            print(f"{d}: no row.json, skipped")
            continue
        with open(path) as f:
            old = json.load(f)
        meta = {k: old[k] for k in META_KEYS if k in old}
        meta.setdefault("pool_limit", 0)
        try:
            with open(f"{d}/summary.json") as f:
                summary = json.load(f)
        except FileNotFoundError:
            summary = {"metrics": {}}
        with open(f"bench/vm/generated/cold-{old['registry']}.json") as f:
            images = c.select_images(json.load(f)["images"], old["class"], old["scenario"],
                                     meta["pool_limit"], old["image_index"])
        row = c.step_row(meta, c.k6_counts(summary), prom_figures(old["start"], old["end"], old["k6_end"]),
                         {k: old[k] for k in UP_KEYS}, images)
        if "integrity" in old:
            row["integrity"] = old["integrity"]
        elif old["scenario"] == "stampede":
            try:
                with open(f"{d}/verify.json") as f:
                    verify = json.load(f)
            except (OSError, ValueError):
                verify = None
            row["integrity"] = c.integrity_from_verify(verify)
        with open(path, "w") as f:
            json.dump(row, f, indent=2)
        rows.append(row)
        print(f"{d}: cpu_s {c._f(old.get('cpu_s'), 1)} -> {c._f(row['cpu_s'], 1)}")
    with open(a.log, "w") as f:
        f.write(c.MD_HEADER + "\n")
        for r in rows:
            f.write(c.markdown_row(r) + "\n")


def append(a):
    with open(a.row) as f:
        row = {**json.load(f), "integrity": a.integrity}
    with open(a.row, "w") as f:
        json.dump(row, f, indent=2)
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
    r = sub.add_parser("recompute")
    r.add_argument("--log", required=True)
    r.add_argument("run_dirs", nargs="+")
    a = ap.parse_args()
    {"collect": collect, "append": append, "recompute": recompute}[a.cmd](a)


if __name__ == "__main__":
    main()
