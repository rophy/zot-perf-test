# zot warm-cache throughput per CPU thread — single host (in progress)

Date: 2026-09-29 · Step log: [`steps-log.md`](2026-09-29-zot-local-per-thread/steps-log.md) · Raw runs: [`runs/`](2026-09-29-zot-local-per-thread/runs/)

## Setup

- Host: Intel Core i7-13620H (hybrid: 6 P-cores × 2 threads = CPUs 0–11, up to 4.7–4.9 GHz; 4 E-cores = CPUs 12–15), 62 GiB RAM, local NVMe. Shared dev machine (other workloads present; load average checked < 5 before each step).
- Harness: [`bench/local/`](../../bench/local/) — docker compose, zot v2.1.21 pinned with `cpuset` to P-core threads and `GOMAXPROCS` = thread count; k6 v2.3.0 pinned to every CPU whose physical core zot does not use (a zot thread's hyperthread sibling stays idle); upstream `registry:2`, Prometheus and node_exporter on E-cores.
- Traffic over a docker bridge (no NIC limit). Plain HTTP (production terminates TLS at an ingress gateway).
- Same 6 images / digests as the EC2 run; warm in zot's page cache (disk read IOPS ≈ 0).
- One step = one k6 run, 40 s, stats averaged over steady state (first 20 s skipped). VUs increased until zot CPU ≥ 95% of its cap.
- `zot cores` = `rate(process_cpu_seconds_total)`; zot network = receive bytes on zot's host-side veth.

## Results

| zot CPUs | Layout | Class | Saturated at | MB/s | Gbps | pulls/s | p50 / p99 | zot cores / cap | k6 CPU |
|---|---|---|---|---:|---:|---:|---|---|---:|
| 4 | 1 thread | 10MB | 2 VUs | 2086 | 16.7 | 170 | 12 / 19 ms | 0.98 / 1 | 18% |
| 4,6 | 2 threads, separate cores | 10MB | 4 VUs | 4334 | 34.7 | 354 | 11 / 25 ms | 1.91 / 2 | 33% |
| 4,6,8 | 3 threads, separate cores | 10MB | 6 VUs | 6343 | 50.7 | 518 | 11 / 23 ms | 2.88 / 3 | 49% |
| 4,5 | 2 threads, same core (HT siblings) | 10MB | 2 VUs | 3079 | 24.6 | 252 | 8 / 13 ms | 1.93 / 2 | 23% |
| 4 | 1 thread | 100MB | 1 VU | 2295 | 18.4 | 23.6 | 43 / 56 ms | 0.98 / 1 | 16% |
| 4 | 1 thread | 1GB | 1 VU | 2537 | 20.3 | 2.7 | 356 / 659 ms | 0.99 / 1 | 16% |

zot RSS 162–168 MB in every step; zero failed pulls; disk read IOPS ≈ 0 (disk write IOPS ≈ 70–90 are host background).

## Findings so far

1. **Linear scaling across physical cores:** 1 → 2 → 3 threads = 2086 → 4334 → 6343 MB/s (≈ 2.1–2.2 GB/s per P-core thread for 10MB images). The saturation point scales too (2 → 4 → 6 VUs).
2. **Hyperthread sibling ≈ 0.5 extra thread:** both threads of one core give 3079 MB/s vs 2086 for one thread (+48%).
3. **Larger blobs are cheaper per byte:** 1 thread serves 2.1 GB/s (10MB), 2.3 GB/s (100MB), 2.5 GB/s (1GB).
4. **Memory does not scale with load or threads** (~165 MB RSS); throughput depends on page cache holding the hot images.

## Caveats

- Absolute numbers are specific to this CPU (desktop-class P-cores, turbo); use as reference, relative scaling is the point.
- 3-thread steps ran with host load 4.4–6.2 (other workloads); k6 CPU reached 49%, still below the 70% validity limit.
- The first 1-core row (01:16) is invalid (host load spike 10.6) and is marked in the step log.
- Single run per step (no repeats).
