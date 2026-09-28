#!/usr/bin/env python3
"""Decide after a step whether the concurrency ladder should stop. Exit 3 = stop."""
import os
import sys

import benchlib as b


def main():
    results_dir, run_id = sys.argv[1], sys.argv[2]
    step = next(s for s in b.read_steps(f"{results_dir}/steps.csv") if s["run_id"] == run_id)
    qf = b.http_query_fn(os.environ.get("PROM_URL", "http://localhost:9090"))
    stats = b.node_stats(qf, step["start_epoch"], step["end_epoch"])
    sat, valid = b.verdict(stats, step["exit_code"])
    print(f"stepcheck {run_id}: saturation={sat} valid={valid} stats={stats}")
    sys.exit(3 if sat in ("threshold", "zot-nic") else 0)


if __name__ == "__main__":
    main()
