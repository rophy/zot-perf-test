"""Cold-pull step analysis: quiet-window detection, upstream access-log parsing, step rows."""
import re
import time

QUIET_BPS = 1e6
QUIET_HOLD_S = 10

_ACCESS = re.compile(r'"(?P<method>GET|HEAD) /v2/(?P<repo>\S+)/(?P<kind>blobs|manifests)/\S+ HTTP/[\d.]+" '
                     r'(?P<status>\d{3}) (?P<bytes>\d+|-)')


def quiet_end(samples, after, bps=QUIET_BPS, hold=QUIET_HOLD_S):
    """First sample time t such that a base sample at or before t-hold, taken no earlier than
    `after`, shows both counters growing by less than `bps` bytes/s. None if not quiet yet."""
    for i, (t, up, disk) in enumerate(samples):
        base = [s for s in samples[:i] if after <= s[0] <= t - hold]
        if not base:
            continue
        t0, up0, disk0 = base[-1]
        dt = t - t0
        if (up - up0) / dt < bps and (disk - disk0) / dt < bps:
            return t
    return None


def parse_access_log(lines, prefix="cold/"):
    out = {"blob_gets": 0, "blob_bytes": 0, "blob_heads": 0, "manifest_gets": 0, "manifest_heads": 0}
    for line in lines:
        m = _ACCESS.search(line)
        if not m or not m["repo"].startswith(prefix):
            continue
        ok = m["status"] in ("200", "206")
        if m["kind"] == "blobs":
            if m["method"] == "HEAD":
                out["blob_heads"] += 1
            elif ok:
                out["blob_gets"] += 1
                out["blob_bytes"] += 0 if m["bytes"] == "-" else int(m["bytes"])
        else:
            out["manifest_heads" if m["method"] == "HEAD" else "manifest_gets"] += 1
    return out


def select_images(images, cls, scenario, pool_limit, image_index):
    pool = [i for i in images if i["class"] == cls]
    if pool_limit > 0:
        pool = pool[:pool_limit]
    return pool if scenario == "unique" else [pool[image_index]]


def k6_counts(summary):
    m = summary.get("metrics", {})
    dur = m.get("image_pull_duration", {})
    return {
        "pulls": m.get("image_pulls", {}).get("count", 0),
        "bytes": m.get("image_pull_bytes", {}).get("count", 0),
        "failed": m.get("image_pull_failed", {}).get("passes", 0),
        **{f"err_{k}": m.get(f"pull_err_{k}", {}).get("count", 0) for k in ("timeout", "4xx", "5xx", "other")},
        "p50_ms": dur.get("med"),
        "p99_ms": dur.get("p(99)"),
    }


def step_row(meta, k6, prom, up, images):
    unique_bytes = sum(i["size"] for i in images)
    unique_blobs = sum(i["layers"] + 1 for i in images)        # + config blob
    window = meta["end"] - meta["start"]
    k6_s = meta["k6_end"] - meta["start"]
    gb = k6["bytes"] / 1e9
    cpu = prom.get("cpu_s")
    return {
        **meta, **k6, **prom, **up,
        "images": len(images), "unique_blobs": unique_blobs, "gb_served": gb,
        "window_s": window, "k6_s": k6_s, "tail_s": meta["end"] - meta["k6_end"],
        "mb_per_s": k6["bytes"] / 1e6 / k6_s if k6_s else None,
        "cpu_s_per_gb": cpu / gb if cpu is not None and gb else None,
        "vm_cores": cpu / window if cpu is not None and window else None,
        "dedup_x": up["blob_bytes"] / unique_bytes if unique_bytes else None,
        "cold_ok": up["blob_gets"] >= unique_blobs,
    }


MD_HEADER = """# Cold-pull steps (temporary)

VM: multipass, Ubuntu 24.04, 4 vCPU, 8 GiB; k6 on the host; one registry at a time. Window = k6 start until upstream tx and VM disk writes < 1 MB/s for 10 s. CPU = busy VM CPU-seconds over the window.

| time (UTC) | registry | scenario | class | VUs | img idx | images | GB served | k6 s | window s | MB/s | p50 ms | p99 ms | failed | timeouts | 5xx | VM CPU-s | CPU-s/GB | VM cores | mem peak MB | mem avg MB | disk wr MB | disk wr IOPS | up blob GETs | up blob GB | dedup × | cold ok | integrity | host CPU % | run dir | k6 rc |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---:|---|---|"""


def _f(x, p=0):
    if x is None:
        return "n/a"
    return f"{x:.{p}f}" if isinstance(x, float) else str(x)


def markdown_row(r):
    window = r["window_s"] or 1
    cells = [
        time.strftime("%H:%M", time.gmtime(r["start"])), r["registry"], r["scenario"], r["class"],
        r["vus"], r["image_index"] if r["scenario"] == "stampede" else "-", r["images"],
        _f(r["gb_served"], 2), r["k6_s"], f'{r["window_s"]}{" (cap)" if r["capped"] else ""}',
        _f(r["mb_per_s"]), _f(r["p50_ms"]), _f(r["p99_ms"]), r["failed"], r["err_timeout"], r["err_5xx"],
        _f(r["cpu_s"], 1), _f(r["cpu_s_per_gb"], 1), _f(r["vm_cores"], 2), _f(r["mem_peak_mb"]),
        _f(r["mem_avg_mb"]), _f(r["disk_wr_mb"]), _f(r["disk_wr_ops"] / window if r["disk_wr_ops"] is not None else None),
        r["blob_gets"], _f(r["blob_bytes"] / 1e9, 2), _f(r["dedup_x"], 2), "yes" if r["cold_ok"] else "NO",
        r.get("integrity", "-"), _f(r["host_cpu_pct"]), r["run_dir"].removeprefix("results/"),
        "FAIL" if r.get("summary_missing") else r["k6_exit"],
    ]
    return "| " + " | ".join(str(c) for c in cells) + " |"
