import coldlib as c

LOG = [
    '1.2.3.4 - - [04/Oct/2026:10:00:00 +0000] "GET /v2/cold/c10m-001/blobs/sha256:aa HTTP/1.1" 200 2500000 "" "x"\n',
    '1.2.3.4 - - [04/Oct/2026:10:00:00 +0000] "GET /v2/cold/c10m-001/blobs/sha256:bb HTTP/1.1" 206 1000 "" "x"\n',
    '1.2.3.4 - - [04/Oct/2026:10:00:00 +0000] "HEAD /v2/cold/c10m-001/blobs/sha256:aa HTTP/1.1" 200 0 "" "x"\n',
    '1.2.3.4 - - [04/Oct/2026:10:00:00 +0000] "GET /v2/cold/c10m-001/manifests/sha256:cc HTTP/1.1" 200 900 "" "x"\n',
    '1.2.3.4 - - [04/Oct/2026:10:00:00 +0000] "HEAD /v2/cold/c10m-001/manifests/sha256:cc HTTP/1.1" 200 - "" "x"\n',
    '1.2.3.4 - - [04/Oct/2026:10:00:00 +0000] "GET /v2/bench/registry/blobs/sha256:dd HTTP/1.1" 200 99 "" "x"\n',
    '1.2.3.4 - - [04/Oct/2026:10:00:00 +0000] "GET /v2/cold/c10m-001/blobs/sha256:ee HTTP/1.1" 404 10 "" "x"\n',
    'time="2026-10-04T10:00:00Z" level=info msg="response completed" http.request.method=GET\n',
]


def test_parse_access_log_counts_cold_repos_only():
    assert c.parse_access_log(LOG) == {"blob_gets": 2, "blob_bytes": 2_501_000, "blob_heads": 1,
                                       "manifest_gets": 1, "manifest_heads": 1}


def test_quiet_end_needs_hold_after_k6_end():
    mb = 1_000_000
    # t, upstream bytes, disk bytes: busy until t=14, then flat.
    s = [(10, 0, 0), (12, 50 * mb, 50 * mb), (14, 90 * mb, 90 * mb), (16, 90 * mb, 90 * mb),
         (20, 90 * mb, 92 * mb), (24, 90 * mb, 93 * mb), (26, 90 * mb, 93 * mb)]
    # quiet from t=14: the first t with a base sample at t-10 >= 14 and < 1 MB/s growth is 24.
    assert c.quiet_end(s, after=14) == 24


def test_quiet_end_none_while_busy():
    s = [(t, t * 5_000_000, 0) for t in range(0, 40, 2)]
    assert c.quiet_end(s, after=0) is None


def test_select_images():
    imgs = [{"class": "c10m", "repo": f"r{i}"} for i in range(5)] + [{"class": "s1g", "repo": "big"}]
    assert [i["repo"] for i in c.select_images(imgs, "c10m", "unique", 0, 0)] == ["r0", "r1", "r2", "r3", "r4"]
    assert [i["repo"] for i in c.select_images(imgs, "c10m", "unique", 2, 0)] == ["r0", "r1"]
    assert [i["repo"] for i in c.select_images(imgs, "c10m", "stampede", 0, 3)] == ["r3"]


def test_k6_counts():
    s = {"metrics": {
        "image_pulls": {"count": 10, "rate": 1.0}, "image_pull_bytes": {"count": 1e9, "rate": 1e8},
        "image_pull_failed": {"value": 0.1, "passes": 1, "fails": 10},
        "pull_err_timeout": {"count": 1, "rate": 0.1},
        "image_pull_duration": {"med": 50, "p(99)": 120},
    }}
    assert c.k6_counts(s) == {"pulls": 10, "bytes": 1e9, "failed": 1, "err_timeout": 1, "err_4xx": 0,
                              "err_5xx": 0, "err_other": 0, "p50_ms": 50, "p99_ms": 120}


def _row(**over):
    meta = {"registry": "zot", "scenario": "stampede", "class": "s1g", "vus": 4, "image_index": 0,
            "start": 100, "k6_end": 130, "end": 140, "capped": False, "k6_exit": 0, "run_dir": "results/x"}
    k6 = {"pulls": 4, "bytes": 4e9, "failed": 0, "err_timeout": 0, "err_4xx": 0, "err_5xx": 0,
          "err_other": 0, "p50_ms": 20000, "p99_ms": 25000}
    prom = {"cpu_s": 8.0, "disk_wr_mb": 1100.0, "disk_wr_ops": 2000.0, "mem_peak_mb": 900.0,
            "mem_avg_mb": 800.0, "host_cpu_pct": 20.0}
    up = {"blob_gets": 9, "blob_bytes": 1e9, "blob_heads": 0, "manifest_gets": 1, "manifest_heads": 0}
    images = [{"size": 1e9, "layers": 8}]
    meta.update(over)
    return c.step_row(meta, k6, prom, up, images)


def test_step_row_derived_fields():
    r = _row()
    assert r["window_s"] == 40 and r["k6_s"] == 30 and r["tail_s"] == 10
    assert r["gb_served"] == 4.0 and r["cpu_s_per_gb"] == 2.0 and r["vm_cores"] == 0.2
    assert round(r["mb_per_s"], 1) == 133.3
    assert r["unique_blobs"] == 9 and r["dedup_x"] == 1.0 and r["cold_ok"] is True
    assert "url" not in r


def test_step_row_cold_check_fails_when_blobs_missing():
    r = _row()
    r2 = c.step_row({**{k: r[k] for k in ("registry", "scenario", "class", "vus", "image_index", "start",
                                          "k6_end", "end", "capped", "k6_exit", "run_dir")}},
                    {"pulls": 4, "bytes": 4e9, "failed": 0, "err_timeout": 0, "err_4xx": 0, "err_5xx": 0,
                     "err_other": 0, "p50_ms": 1, "p99_ms": 1},
                    {"cpu_s": 1.0, "disk_wr_mb": 0, "disk_wr_ops": 0, "mem_peak_mb": 1, "mem_avg_mb": 1,
                     "host_cpu_pct": 1},
                    {"blob_gets": 3, "blob_bytes": 1, "blob_heads": 0, "manifest_gets": 0, "manifest_heads": 0},
                    [{"size": 1e9, "layers": 8}])
    assert r2["cold_ok"] is False


def test_markdown_row_has_header_columns():
    line = c.markdown_row({**_row(), "integrity": "ok"})
    assert line.startswith("| ") and line.count("|") == c.MD_HEADER.splitlines()[-1].count("|")
    assert "| zot | stampede | s1g | 4 |" in line


def test_markdown_row_k6_rc_cell():
    ok = c.markdown_row({**_row(), "integrity": "ok"})
    assert ok.rstrip(" |").endswith("| x | 0")
    bad = c.markdown_row({**_row(summary_missing=True), "integrity": "ok"})
    assert bad.rstrip(" |").endswith("| x | FAIL")
    assert bad.count("|") == c.MD_HEADER.splitlines()[-1].count("|")


def _cells(line):
    return [x.strip() for x in line.strip().strip("|").split(" | ")]


def _header_cells():
    return _cells(c.MD_HEADER.splitlines()[-2])


def test_markdown_row_iowait_column_after_vm_cores():
    h = _header_cells()
    i = h.index("iowait s")
    assert h[i - 1] == "VM cores"
    line = c.markdown_row({**_row(), "iowait_s": 12.34, "integrity": "ok"})
    assert _cells(line)[i] == "12.3"


def test_markdown_row_iowait_missing_is_na():
    h = _header_cells()
    i = h.index("iowait s")
    line = c.markdown_row({**_row(), "integrity": "ok"})
    assert _cells(line)[i] == "n/a"
    assert line.count("|") == c.MD_HEADER.splitlines()[-1].count("|")
