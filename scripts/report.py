#!/usr/bin/env python3
"""Generate report.md from a results directory."""
import json
import os
import statistics
import sys
from collections import defaultdict

import benchlib as b


def fmt(v, nd=1):
    return "n/a" if v is None else f"{v:.{nd}f}"


def median_or_none(vals):
    vals = [v for v in vals if v is not None]
    return statistics.median(vals) if vals else None


def spread(vals):
    vals = [v for v in vals if v is not None]
    return (max(vals) - min(vals)) if len(vals) > 1 else None


def build_rows(results_dir, query_fn):
    rows = []
    for s in b.read_steps(f"{results_dir}/steps.csv"):
        k6 = b.summarize_k6(b.load_summary(results_dir, s["run_id"]))
        stats = b.node_stats(query_fn, s["start_epoch"], s["end_epoch"])
        sat, valid = b.verdict(stats, s["exit_code"])
        rows.append({**s, **k6, **stats, "saturation": sat, "valid": valid})
    return rows


def render(rows, env):
    out = ["# zot warm-cache throughput report", ""]
    out.append(f"- zot: {env.get('zot_version', 'n/a')}  config sha256: {env.get('zot_config_sha256', 'n/a')}")
    out.append(f"- instances: zot={env.get('zot_instance_type', 'n/a')} client={env.get('client_instance_type', 'n/a')}")
    out.append(f"- kernel: {env.get('kernel', 'n/a')}  k6: {env.get('k6_version', 'n/a')}")
    if env.get("label"):
        out.append(f"- variant: {env['label']}")
    out.append("")
    groups = defaultdict(list)
    for r in rows:
        groups[(r["class"], r["drop_caches"], r["vus"])].append(r)
    for (cls, dc) in sorted({(c, d) for c, d, _ in groups}):
        title = f"{cls}" + (" (disk-warm, caches dropped)" if dc else " (page-cache warm)")
        out += [f"## {title}", "",
                "| VUs | pulls/s (median) | spread | MB/s | p50 ms | p99 ms | max ms | fail % | zot CPU % | zot cores | zot RSS MB | zot NIC Gbps | zot disk MB/s | client CPU % | saturation | valid |",
                "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|"]
        xs, ys = [], []
        for vus in sorted(v for c, d, v in groups if c == cls and d == dc):
            g = groups[(cls, dc, vus)]
            med = lambda k: median_or_none([r[k] for r in g])
            sats = sorted({r["saturation"] for r in g})
            valid = all(r["valid"] for r in g)
            pps = med("pulls_per_s")
            out.append(f"| {vus} | {fmt(pps, 2)} | {fmt(spread([r['pulls_per_s'] for r in g]), 2)} | {fmt(med('mb_per_s'))} "
                       f"| {fmt(med('p50_ms'), 0)} | {fmt(med('p99_ms'), 0)} | {fmt(med('max_ms'), 0)} "
                       f"| {fmt((med('fail_rate') or 0) * 100, 2)} | {fmt(med('zot_cpu_pct'))} | {fmt(med('zot_proc_cores'), 2)} | {fmt(med('zot_rss_mb'), 0)} "
                       f"| {fmt(med('zot_nic_tx_gbps'), 2)} | {fmt(med('zot_disk_read_mbps'))} | {fmt(med('client_cpu_pct'))} "
                       f"| {','.join(sats)} | {'yes' if valid else 'NO'} |")
            xs.append(str(vus)); ys.append(round(med("mb_per_s") or 0, 1))
        out += ["", "```mermaid", "xychart-beta", f'  title "{title}: MB/s vs VUs"',
                f"  x-axis [{', '.join(xs)}]", '  y-axis "MB/s"', f"  line [{', '.join(map(str, ys))}]", "```", ""]
    return "\n".join(out) + "\n"


def main():
    results_dir = sys.argv[1]
    env_path = f"{results_dir}/env.json"
    env = json.load(open(env_path)) if os.path.exists(env_path) else {}
    rows = build_rows(results_dir, b.http_query_fn(os.environ.get("PROM_URL", "http://localhost:9090")))
    with open(f"{results_dir}/report.md", "w") as f:
        f.write(render(rows, env))
    with open(f"{results_dir}/rows.json", "w") as f:
        json.dump(rows, f, indent=2)
    print(f"wrote {results_dir}/report.md")


if __name__ == "__main__":
    main()
