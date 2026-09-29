# zot Pull-Through Cache — Warm Throughput Test Report

| | |
|---|---|
| Date | 2026-09-28 – 2026-09-29 |
| Subject | zot v2.1.21 as an edge pull-through cache, **warm-cache** pull throughput |
| Environments | AWS EC2 (2 × m6idn.2xlarge) and a single local host (Intel i7-13620H) |
| Status | Phase 1 (warm throughput) complete. Cold pulls, disk-bound serving, GC/lock contention, HA not yet tested. |

## 1. Executive summary

1. **CPU is not the sizing constraint for serving cached images.** One CPU thread of zot serves **~2.1–2.5 GB/s (17–20 Gbps)** on the local host and **~2.6–3.4 GB/s (21–27 Gbps)** on EC2, from page cache, over plain HTTP.
2. **Throughput scales linearly with CPU threads** on separate physical cores: 1 / 2 / 3 threads = 2086 / 4334 / 6343 MB/s (1.00× / 2.08× / 3.04×).
3. **With no CPU limit, zot saturated a 40 Gbps NIC at ~50% of 8 vCPUs** after only 4 concurrent clients.
4. **Memory is flat at ~160–190 MB RSS** regardless of load, threads or image size. RAM matters only as **page cache** for the hot image set.
5. **Past CPU saturation zot degrades gracefully:** throughput stays flat, latency rises linearly with queued clients, zero errors up to 64 concurrent clients per core.
6. **What sizes an edge node:** NIC bandwidth, RAM for page cache (hot set), and disk throughput for whatever does not fit in RAM (not yet measured). A few cores give ample headroom.

## 2. Context

- Architecture under evaluation: one source registry, many regional edge sites; each site runs **2 active zot instances behind a load balancer**, each with its own local storage, pulling from the source on demand.
- Production edge hardware is **not AWS**; EC2 and the local host are test beds. Per-core figures are **reference values** — the relative behaviour (scaling, saturation) is what transfers.
- **TLS is terminated at a corporate ingress gateway**; zot serves plain HTTP. All results below are plain HTTP.

## 3. Test design

### 3.1 Workload

Six public images copied (linux/amd64, pinned by digest) into the source registry:

| Class | Image | Compressed size | Layers |
|---|---|---:|---:|
| 10MB | `registry:2` | 10 MB | 5 |
| 10MB | `haproxy:3.0-alpine` | 14 MB | 6 |
| 100MB | `eclipse-temurin:21-jre` | 114 MB | 6 |
| 100MB | `node:22-slim` | 79 MB | 5 |
| 1GB | `selenium/standalone-chrome` | 1003 MB | 38 |
| 1GB | `sonarqube:10-community` | 856 MB | 8 |

- **Client model** (k6 v2.3.0, [`k6/pull.js`](../../k6/pull.js)): one virtual user (VU) = one client looping full image pulls **by digest**: `GET manifest`, then config + all layers with 3 blobs in parallel (docker/containerd default). Each response's `Content-Length` is checked against the manifest.
- **Warm cache:** every image was pulled through zot once beforehand and verified on zot's disk; timed runs never touched the source registry (verified: no sync activity in zot logs during runs, and all pulls succeed with the upstream stopped in local tests).
- zot config ([`zot/render-config.sh`](../../zot/render-config.sh)): local storage, `dedupe: false`, `gc: false`, sync `onDemand` + `preserveDigest` (requires `http.compat: ["docker2s2"]`), metrics enabled.

### 3.2 Metrics and rules

- Throughput (MB/s, pulls/s) and per-image pull latency (p50/p99) from k6.
- zot CPU = `rate(process_cpu_seconds_total)` (user + system, in cores); zot RSS; zot network egress; disk read/write IOPS; load-generator CPU.
- Stats averaged over each step's steady state (first 20 s skipped).
- A step is **invalid** if the load generator's CPUs exceed 70% busy. **Saturation** = zot CPU ≥ 95% of its cap.

### 3.3 Environments

| | EC2 | Local host |
|---|---|---|
| zot node | m6idn.2xlarge (Intel Xeon Ice Lake 3.5 GHz, 8 vCPU / 4 cores, 32 GiB), instance-store NVMe (XFS) | Intel Core i7-13620H: 6 P-cores × 2 threads (CPUs 0–11, up to 4.7–4.9 GHz) + 4 E-cores; 62 GiB; NVMe |
| Load generator | separate m6idn.2xlarge, same AZ, cluster placement group | same host, pinned to CPUs not used by zot |
| Network | ENA, 12.5 Gbps baseline; **measured 39.7 Gbps sustained** (burst) with iperf3 | docker bridge (no NIC limit) |
| CPU limiting | `GOMAXPROCS` only | `cpuset` pinning to P-core threads + `GOMAXPROCS` = thread count; a zot thread's hyperthread sibling left idle |
| Source registry | Amazon ECR (same region) | local `registry:2` (same digests) |
| OS / runtime | Amazon Linux 2023, kernel 6.18; zot binary under systemd | docker compose ([`bench/local/`](../../bench/local/)) |

## 4. Results

### 4.1 EC2 — no CPU limit (default GOMAXPROCS = 8)

10MB class, 30 s steps:

| VUs | MB/s | Gbps | p50 / p99 | zot node CPU | client CPU |
|---:|---:|---:|---|---:|---:|
| 1 | 1745 | 14.0 | 8 / 9 ms | 16% | 14% |
| 4 | 4960 | **39.8** | 10 / 15 ms | **49%** | 48% |

**The NIC (39.7 Gbps measured) was saturated at 4 clients with half of the CPU idle.** CPU split of the zot process at this point (30 s, `/proc/<pid>/stat`): **0.81 cores user + 2.17 cores system (73% kernel)**.

### 4.2 EC2 — zot limited to one thread (GOMAXPROCS = 1)

60 s steps. `GOMAXPROCS=1` capped total zot CPU (user + kernel) at exactly 1.00 core.

| Class | VUs | MB/s | Gbps | pulls/s | p50 | p99 | zot cores | zot RSS MB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 10MB | 1 | 1496 | 12.0 | 122.2 | 9 ms | 11 ms | 0.61 | 170 |
| 10MB | 4 | **2661** | 21.4 | 217.3 | 18 ms | 31 ms | 0.99 | 171 |
| 10MB | 16 | 2598 | 20.9 | 212.1 | 75 ms | 114 ms | 1.00 | 174 |
| 10MB | 64 | 2631 | 21.2 | 214.8 | 290 ms | 401 ms | 1.00 | 185 |
| 100MB | 1 | 1809 | 14.5 | 18.6 | 52 ms | 65 ms | 0.49 | 175 |
| 100MB | 4 | **3461** | 27.9 | 35.5 | 112 ms | 164 ms | 1.00 | 176 |
| 100MB | 16 | 3266 | 26.5 | 33.5 | 472 ms | 633 ms | 1.00 | 177 |
| 100MB | 64 | 3145 | 25.3 | 32.3 | 1968 ms | 2646 ms | 1.00 | 189 |
| 1GB | 1 | 1776 | 14.2 | 1.9 | 659 ms | 671 ms | 0.51 | 176 |
| 1GB | 4 | **3371** | 27.3 | 3.6 | 1103 ms | 1401 ms | 1.00 | 177 |
| 1GB | 16 | 3400 | 27.4 | 3.6 | 4294 ms | 5520 ms | 1.00 | 179 |
| 1GB | 64 | 3305 | 26.8 | 3.5 | 17087 ms | 23923 ms | 1.00 | 191 |

Zero failed pulls; client CPU ≤ 25%. Beyond saturation (4 VUs) throughput is flat and p50 grows ~linearly with VUs (queueing).

### 4.3 Local host — per-thread scaling (pinned)

40 s steps; VUs raised until zot CPU reached its cap.

| zot CPUs | Layout | Class | Saturated at | MB/s | Gbps | pulls/s | p50 / p99 | zot cores / cap | load-gen CPU |
|---|---|---|---:|---:|---:|---:|---|---|---:|
| 4 | 1 thread | 10MB | 2 VUs | **2086** | 16.7 | 170 | 12 / 19 ms | 0.98 / 1 | 18% |
| 4,6 | 2 threads, 2 cores | 10MB | 4 VUs | **4334** | 34.7 | 354 | 11 / 25 ms | 1.91 / 2 | 33% |
| 4,6,8 | 3 threads, 3 cores | 10MB | 6 VUs | **6343** | 50.7 | 518 | 11 / 23 ms | 2.88 / 3 | 49% |
| 4,5 | 2 threads, 1 core (HT siblings) | 10MB | 2 VUs | 3079 | 24.6 | 252 | 8 / 13 ms | 1.93 / 2 | 23% |
| 4 | 1 thread | 100MB | 1 VU | **2295** | 18.4 | 23.6 | 43 / 56 ms | 0.98 / 1 | 16% |
| 4 | 1 thread | 1GB | 1 VU | **2537** | 20.3 | 2.7 | 356 / 659 ms | 0.99 / 1 | 16% |

zot RSS 162–168 MB in every step; disk read IOPS ≈ 0 (page cache); zero failed pulls. zot egress measured on its veth matched k6's received bytes.

### 4.4 Local host — TLS smoke (informational)

zot serving HTTPS itself, CPUs 4,5 (one physical core, GOMAXPROCS 2), 10MB, 30 s: **3349 MB/s plain vs 1045 MB/s TLS (≈3.2× more CPU per byte)**. Not pursued further because TLS terminates at the ingress gateway — relevant to gateway sizing, not zot.

## 5. Analysis

### 5.1 Per-thread throughput and scaling

| Class | Local, 1 P-core thread | EC2, GOMAXPROCS = 1 |
|---|---:|---:|
| 10MB | 2.09 GB/s | 2.66 GB/s |
| 100MB | 2.30 GB/s | 3.46 GB/s |
| 1GB | 2.54 GB/s | 3.37 GB/s |

- **Scaling is linear across physical cores** (2.08× at 2 threads, 3.04× at 3 threads), and the client count needed to saturate scales with it (2 → 4 → 6 VUs).
- **A hyperthread sibling adds ~48%** (3079 vs 2086 MB/s), i.e. two HT threads ≈ 1.5 threads on separate cores.
- **Larger blobs are cheaper per byte** (per-request overhead amortised): 10MB costs ~10–30% more CPU per byte than 100MB/1GB.
- The EC2 figures are higher than the local ones despite a lower clock. Likely contributors (not isolated): on EC2 the kernel's receive/interrupt work ran on other vCPUs outside zot's limit, and the ENA NIC offloads segmentation, whereas the local docker bridge (veth) path does that work in software. Treat both as reference ranges: **~2–3.5 GB/s per thread**.

### 5.2 Where zot spends CPU

- ~73% of zot's CPU is kernel time (EC2 measurement, 4.1).
- From the v2.1.21 source: blobs are streamed with `io.CopyN` in 10 MB chunks (`pkg/api/routes.go`), and the response writer is wrapped (`statusWriter`, `pkg/api/session.go`) without `ReaderFrom`, so Go cannot use `sendfile`: data is copied page cache → user buffer → socket via `read`/`write`. This is consistent with the high system share but **not yet confirmed with a syscall trace**.
- Implication: throughput per core is bound mostly by memory-copy cost in the kernel; zot's own logic is a small share for multi-MB blobs. A zero-copy path could raise per-core throughput further.

### 5.3 Behaviour under overload

Once CPU-bound, adding clients does not reduce throughput or cause errors; latency grows linearly with the number of queued clients (e.g. EC2 1 thread, 10MB: p50 18 → 75 → 290 ms at 4 → 16 → 64 VUs). No memory growth was observed (RSS +~15 MB from 1 to 64 VUs).

### 5.4 Memory

RSS stays ~160–190 MB across all tests. The RAM that matters is **page cache**: all results are for images resident in page cache (disk read IOPS ≈ 0). Serving from disk will be bounded by disk throughput and has not been measured yet.

## 6. Sizing implications (edge node)

| Resource | Guidance from these results |
|---|---|
| CPU | Budget **≥ 1 thread per ~2 GB/s (~16 Gbps)** of peak warm-pull egress, then add headroom for sync, metadata, GC and the OS. For typical 10/25 GbE nodes, **2–4 cores are ample** for warm serving. |
| NIC | Usually the first limit: a 10 GbE link saturates at roughly half a thread. Size to the site's peak pull bandwidth. |
| RAM | ~0.2 GB for zot + **enough page cache for the hot image set** (images pulled during a rollout). |
| Disk | Capacity for the cached catalog; throughput matters when the hot set exceeds RAM (to be measured). |
| HA | 2 active instances per site; size each so **one node alone** carries the site's peak. |

Example: a site whose peak rollout needs 10 Gbps (1.25 GB/s) uses < 1 thread of zot CPU; the NIC is the limit, and a 25 GbE node with 4 cores and RAM ≥ hot set + a few GB has large headroom.

## 7. Limitations

- **Single run per step** (no repeats); run-to-run spread not quantified. The local host is a shared dev machine (load average checked < 5 before each step; one step during a load spike was discarded).
- **Warm, page-cache-resident images only.**
- **Whole-image pulls only;** metadata-heavy traffic (frequent manifest/`HEAD` polling) was not tested — the one pattern where per-request CPU could dominate.
- **≤ 64 concurrent clients** per step; behaviour with hundreds of simultaneous clients untested.
- 100MB and 1GB were measured at 1 thread only locally; multi-thread scaling assumed from the 10MB class.
- Absolute per-core figures depend on CPU model, clock and network path.

## 8. Not yet tested / next phases

| Area | Why it matters | Known upstream issues |
|---|---|---|
| **Cold pulls (on-demand sync)** | zot fully caches an image before serving it; first pull of a large image delays time-to-first-byte | [#3463](https://github.com/project-zot/zot/issues/3463), streaming in [PR #3778](https://github.com/project-zot/zot/pull/3778) (open) |
| **Concurrent first pulls across the HA pair** | both instances may fetch the same image from the source | [#4399](https://github.com/project-zot/zot/issues/4399), [#4215](https://github.com/project-zot/zot/issues/4215) |
| **GC / retention under load** | a global image-store write lock can stall all requests during GC | [#2964](https://github.com/project-zot/zot/issues/2964) (open) |
| **Disk-bound serving** | hot set larger than RAM | — |
| **Metadata-heavy traffic** | CPU per request rather than per byte | — |
| **HA failover** | kill one instance under load; errors and recovery | — |

zot v2.1.21 (used here) already includes fixes for a sync goroutine leak ([#4319](https://github.com/project-zot/zot/issues/4319)), per-pull upstream re-checks ([#4393](https://github.com/project-zot/zot/issues/4393), `manifestCheckInterval`) and HTTP/2 sync throughput ([#4333](https://github.com/project-zot/zot/issues/4333), `disableHTTP2`).

## 9. Reproduction and data

- Design and plan: [`docs/superpowers/specs/`](../superpowers/specs/), [`docs/superpowers/plans/`](../superpowers/plans/).
- EC2: `terraform/infra` (ECR repos, IAM) → `images/preload.sh` → `terraform/app` (nodes) → `scripts/warmup.sh` → `scripts/run-suite.sh`. AWS credentials come from the default credential chain.
- Local: `bench/local/setup.sh`, then `bench/local/step.sh <zot-cpuset> http <class> <vus>` per step.
- Data:
  - EC2 GOMAXPROCS=1: [`2026-09-29-zot-gomaxprocs1/`](2026-09-29-zot-gomaxprocs1/) ([summary](2026-09-29-zot-gomaxprocs1.md))
  - Local per-thread: [`2026-09-29-zot-local-per-thread/`](2026-09-29-zot-local-per-thread/) ([summary](2026-09-29-zot-local-per-thread.md), [step log](2026-09-29-zot-local-per-thread/steps-log.md))
  - EC2 no-limit smoke (4.1): [`2026-09-29-zot-ec2-no-limit-smoke/`](2026-09-29-zot-ec2-no-limit-smoke/). The user/system CPU split was measured interactively from `/proc/<pid>/stat` (not archived).
