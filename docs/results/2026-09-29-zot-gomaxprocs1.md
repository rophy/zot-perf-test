# zot warm-cache throughput — single core (GOMAXPROCS=1)

Date: 2026-09-29 · Raw data: [`2026-09-29-zot-gomaxprocs1/`](2026-09-29-zot-gomaxprocs1/) · Spec: [`../superpowers/specs/2026-09-27-zot-warm-throughput-design.md`](../superpowers/specs/2026-09-27-zot-warm-throughput-design.md)

## Setup

- zot v2.1.21 (`v2.1.21-0-g6429ce6`, go1.26.8), on-demand sync from ECR, `preserveDigest`, `dedupe: false`, `gc: false`, plain HTTP.
- zot node and client node: `m6idn.2xlarge` (8 vCPU / 4 cores, 32 GiB), us-east-1, same AZ, cluster placement group.
- zot storage: instance-store NVMe, XFS. All images warm in page cache (disk reads ≈ 0).
- Load: k6 v2.3.0, one VU = one client looping full image pulls by digest (manifest, then config + layers, 3 blobs in parallel).
- zot restricted with `GOMAXPROCS=1` (systemd drop-in). `zot cores` = `rate(process_cpu_seconds_total)`, user + system.
- Ladder 1 / 4 / 16 / 64 VUs, 60 s per step, 1 repeat. Stats averaged over steady state (first 20 s of each step skipped).

Images (linux/amd64, compressed):

| Class | Images |
|---|---|
| 10MB | `registry:2` (10 MB, 5 layers), `haproxy:3.0-alpine` (14 MB, 6 layers) |
| 100MB | `eclipse-temurin:21-jre` (114 MB, 6 layers), `node:22-slim` (79 MB, 5 layers) |
| 1GB | `selenium/standalone-chrome` (1003 MB, 38 layers), `sonarqube:10-community` (856 MB, 8 layers) |

## Results

| Class | VUs | MB/s | Gbps | p50 | p99 | zot cores | client CPU |
|---|---:|---:|---:|---:|---:|---:|---:|
| 10MB | 1 | 1497 | 12.0 | 9 ms | 11 ms | 0.62 | 13% |
| 10MB | 4 | 2661 | 21.4 | 18 ms | 31 ms | 1.00 | 23% |
| 10MB | 16 | 2598 | 21.0 | 75 ms | 114 ms | 1.00 | 23% |
| 10MB | 64 | 2631 | 21.3 | 290 ms | 401 ms | 1.00 | 23% |
| 100MB | 1 | 1810 | 14.6 | 52 ms | 65 ms | 0.50 | 13% |
| 100MB | 4 | 3461 | 27.9 | 112 ms | 164 ms | 1.00 | 26% |
| 100MB | 16 | 3266 | 26.5 | 472 ms | 634 ms | 1.00 | 24% |
| 100MB | 64 | 3145 | 25.4 | 2.0 s | 2.6 s | 1.00 | 24% |
| 1GB | 1 | 1776 | 14.3 | 0.66 s | 0.67 s | 0.52 | 13% |
| 1GB | 4 | 3372 | 27.3 | 1.1 s | 1.4 s | 1.00 | 25% |
| 1GB | 16 | 3400 | 27.4 | 4.3 s | 5.5 s | 1.00 | 25% |
| 1GB | 64 | 3306 | 26.8 | 17.1 s | 23.9 s | 1.00 | 25% |

Full per-step table: [`report.md`](2026-09-29-zot-gomaxprocs1/report.md). Zero failed pulls in every step; zot RSS ≈ 175 MB throughout.

## Findings

1. **One core of zot serves ~2.6 GB/s (≈21 Gbps) of 10MB images and ~3.3–3.5 GB/s (≈27 Gbps) of 100MB/1GB images** from page cache. Smaller blobs cost more per byte (fixed per-request overhead).
2. **Saturation at 4 VUs; beyond it, throughput is flat and latency grows linearly with load** (pure queueing). No errors, no memory growth.
3. **`GOMAXPROCS=1` caps total zot CPU at exactly 1.00 core**, including kernel time: the 32 KB `read`/`write` syscalls are short enough that the Go runtime does not hand off the P during them.
4. **Serving blobs is mostly kernel copy work.** At default GOMAXPROCS, 10MB × 4 VUs (NIC-bound at ~40 Gbps), zot used ~0.8 cores user + ~2.2 cores system (73% system).
5. **CPU is not the edge-sizing constraint** — NIC bandwidth and page cache / disk throughput are. A 12.5 Gbps NIC saturates at roughly half a zot core.

## Context and caveats

- **NIC burst:** `m6idn.2xlarge` is rated 12.5 Gbps baseline, but iperf3 (8 streams, zot → client) sustained **39.7 Gbps for 60 s** (burst credits). With default GOMAXPROCS (8), 10MB × 4 VUs already filled the NIC (~39.9 Gbps at ~50% node CPU), which is why zot was restricted to 1 core to find a CPU bound.
- **Blob copy path (from source, not yet traced):** zot streams blobs with `io.CopyN` through a response-writer wrapper (`statusWriter`) that does not implement `ReaderFrom`, so Go cannot use `sendfile`; data is copied via a user-space buffer. To be confirmed with `strace -c` under load.
- **Single repeat.** Spread across repeats is not measured yet.
- **Warm page cache only.** Disk-bound serving (caches dropped, EBS gp3) not measured yet.
- **Not measured:** GOMAXPROCS=2 and default runs (interrupted), per-core scaling beyond 1 core, TLS, cold pulls, GC / lock contention (zot issue #2964).

## Next

- Per-core scaling (1 / 2 / 3 cores) on a single machine over loopback with CPU pinning, calibrated against these real-NIC single-core numbers.
- Disk-bound serving on gp3 EBS; validation of a small edge instance.
