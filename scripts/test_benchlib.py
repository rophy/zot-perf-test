import benchlib as b


def test_read_steps(tmp_path):
    p = tmp_path / "steps.csv"
    p.write_text("run_id,class,vus,repeat,start_epoch,end_epoch,exit_code,drop_caches\n"
                 "10MB-v4-r1,10MB,4,1,100,160,0,0\n")
    assert b.read_steps(p) == [{"run_id": "10MB-v4-r1", "class": "10MB", "vus": 4, "repeat": 1,
                                "start_epoch": 100, "end_epoch": 160, "exit_code": 0, "drop_caches": 0}]


def test_summarize_k6():
    s = {"metrics": {
        "image_pulls": {"count": 600, "rate": 10.0},
        "image_pull_bytes": {"count": 6e9, "rate": 1e8},
        "image_pull_duration": {"med": 50, "p(95)": 90, "p(99)": 120, "max": 300, "avg": 55, "min": 10},
        "image_pull_failed": {"value": 0.002, "passes": 1, "fails": 599},
    }}
    assert b.summarize_k6(s) == {"pulls_per_s": 10.0, "mb_per_s": 100.0, "p50_ms": 50, "p95_ms": 90,
                                 "p99_ms": 120, "max_ms": 300, "fail_rate": 0.002}


def test_summarize_k6_no_pulls():
    s = {"metrics": {"image_pull_failed": {"value": 1.0}}}
    got = b.summarize_k6(s)
    assert got["pulls_per_s"] == 0 and got["p99_ms"] is None and got["fail_rate"] == 1.0


def test_prom_avg():
    assert b.prom_avg(lambda q, s, e: [1.0, 2.0, 3.0], "q", 0, 10) == 2.0
    assert b.prom_avg(lambda q, s, e: [], "q", 0, 10) is None


def test_node_stats_uses_all_queries():
    seen = []
    def qf(q, s, e):
        seen.append(q)
        return [1.0]
    stats = b.node_stats(qf, 0, 60)
    assert set(stats) == {"zot_cpu_pct", "zot_proc_cores", "zot_rss_mb", "zot_nic_tx_gbps",
                          "zot_disk_read_mbps", "disk_read_iops", "disk_write_iops", "client_cpu_pct"}
    assert len(seen) == 8


def base(**kw):
    s = {"zot_cpu_pct": 30.0, "zot_rss_mb": 100.0, "zot_nic_tx_gbps": 2.0,
         "zot_disk_read_mbps": 0.0, "client_cpu_pct": 20.0}
    s.update(kw)
    return s


def test_verdict_none():
    assert b.verdict(base(), 0) == ("none", True)


def test_verdict_nic():
    assert b.verdict(base(zot_nic_tx_gbps=12.0), 0) == ("zot-nic", True)


def test_verdict_cpu():
    assert b.verdict(base(zot_cpu_pct=95.0), 0) == ("zot-cpu", True)


def test_verdict_client_invalid():
    assert b.verdict(base(client_cpu_pct=75.0), 0) == ("client", False)


def test_verdict_threshold_abort():
    assert b.verdict(base(), 99) == ("threshold", True)


def test_verdict_missing_client_metric_is_invalid():
    assert b.verdict(base(client_cpu_pct=None), 0) == ("none", False)


def test_report_render_groups_and_flags():
    import report
    rows = [
        {"run_id": f"10MB-v4-r{i}", "class": "10MB", "vus": 4, "repeat": i, "drop_caches": 0,
         "pulls_per_s": 10.0 + i, "mb_per_s": 100.0, "p50_ms": 5, "p95_ms": 9, "p99_ms": 12, "max_ms": 30,
         "fail_rate": 0.0, "zot_cpu_pct": 20.0, "zot_proc_cores": 1.5, "zot_rss_mb": 80.0, "zot_nic_tx_gbps": 0.8,
         "zot_disk_read_mbps": 0.0, "client_cpu_pct": 75.0 if i == 3 else 10.0,
         "saturation": "client" if i == 3 else "none", "valid": i != 3}
        for i in (1, 2, 3)
    ]
    md = report.render(rows, {"zot_version": "v2.1.21"})
    assert "## 10MB (page-cache warm)" in md
    assert "| 4 | 12.00 | 2.00 |" in md       # median of 11,12,13; spread 2
    assert "client,none" in md and "| NO |" in md
    assert "xychart-beta" in md


def test_node_stats_skips_ramp():
    windows = []
    b.node_stats(lambda q, s, e: windows.append((s, e)) or [1.0], 100, 170)
    assert set(windows) == {(120, 170)}


def test_steady_window_short_step():
    assert b.steady_window(100, 130) == (115, 130)
