# Edge Pull-Through Cache — Warm Throughput: zot vs Distribution vs Harbor

| | |
|---|---|
| Dates | 2026-09-28 – 2026-10-03 |
| Question | How much CPU, memory, disk and network does a registry need to serve **cached** images at an edge site? |
| Candidates | zot v2.1.21 · Distribution v3.1.2 (proxy mode) · Harbor v2.15.2 (proxy-cache project) |
| Scope | Warm cache, whole-image pulls, plain HTTP (TLS ends at the ingress gateway). Cold pulls, GC, HA not tested. |

## 1. Findings

1. **CPU per GB/s served (same VM, 10MB images):** zot **≈ 0.9 vCPU** · Distribution **≈ 2.0** · Harbor **≈ 11**. zot uses ~2.2× less CPU than Distribution and ~12× less than Harbor.
2. **Peak on 4 vCPU / 8 GiB:** zot 2210 MB/s (not CPU-bound) · Distribution 1614 MB/s · Harbor 334 MB/s (CPU-bound).
3. **zot scales linearly per core:** 1 / 2 / 3 pinned P-core threads = 2086 / 4334 / 6343 MB/s; one thread ≈ 2–3.5 GB/s depending on CPU and network path.
4. **Harbor = Distribution + a management/proxy layer.** Its data path is nginx → harbor-core → Distribution, each blob is fetched twice (`HEAD` + `GET`), every internal request is bcrypt-authenticated, and Postgres writes on every pull.
5. **Memory is not a constraint:** zot RSS 160–190 MB; whole VM 0.7–1.0 GB for any candidate. RAM is needed as **page cache** for the hot image set.
6. **For zot, the NIC is the limit long before the CPU:** with no CPU limit it filled a 40 Gbps link at ~50% of 8 vCPUs.

## 2. Method

| | |
|---|---|
| Images | 6 public linux/amd64 images, pinned by digest: **10MB** `registry:2` (10 MB, 5 layers), `haproxy:3.0-alpine` (14 MB, 6) · **100MB** `eclipse-temurin:21-jre` (114 MB, 6), `node:22-slim` (79 MB, 5) · **1GB** `selenium/standalone-chrome` (1003 MB, 38), `sonarqube:10-community` (856 MB, 8) |
| Client | k6 v2.3.0; 1 VU = 1 client looping full pulls by digest: manifest, then config + layers (3 in parallel), `Content-Length` checked. Token-auth registries get one anonymous token per pull. |
| Warm cache | Every image pulled once, all blobs verified on the registry's disk, all images pullable with the upstream **stopped**, **0 upstream requests** during timed runs. |
| Steps | 40–60 s per VU level, stats over steady state (first 20 s skipped), VUs raised until saturation. Single run per step. |
| Metrics | Throughput, pull latency (p50/p99), registry CPU, memory, disk IOPS, network egress, load-generator CPU (step invalid if > 70%). |

| Environment | Hardware | CPU limit | Used for |
|---|---|---|---|
| **EC2** | 2 × m6idn.2xlarge (Xeon Ice Lake, 8 vCPU, 32 GiB, NVMe); NIC measured 39.7 Gbps (burst) | `GOMAXPROCS` | zot, real NIC |
| **Local, pinned** | i7-13620H, zot on P-core threads via `cpuset` + `GOMAXPROCS`, k6 on other cores, docker bridge | pinned threads | zot per-thread scaling |
| **VM** | multipass, Ubuntu 24.04, **4 vCPU (unpinned), 8 GiB** on the same i7 host; virtio 31–33 Gbps | VM size | zot vs Distribution vs Harbor |

## 3. Results

### 3.1 Three-way comparison (VM, 10MB)

| VUs | zot MB/s · vCPU | Distribution MB/s · vCPU | Harbor MB/s · vCPU |
|---:|---|---|---|
| 1 | 1229 · 1.32 | 818 · 2.11 | 169 · 2.32 |
| 2 | 1464 · 1.52 | 981 · 2.54 | 239 · 2.93 |
| 4 | 1679 · 1.59 | 1158 · 2.82 | 286 · 3.46 |
| 8 | 1978 · 1.76 | 1403 · 3.02 | **334 · 3.77** |
| 16 | **2210 · 1.90** | **1614 · 3.22** | — |
| 32 | 2200 · 1.94 | — | — |

| At 8 VUs | zot | Distribution | Harbor |
|---|---:|---:|---:|
| pulls/s | 161.5 | 114.6 | 27.2 |
| p50 / p99 | 46 / 107 ms | 67 / 126 ms | 293 / 395 ms |
| VM memory used | 712 MB | 745 MB | 966 MB |
| Disk write IOPS (warm reads only) | 1 | 10 | 353 |

Zero failed pulls. zot never exceeded ~1.9 of 4 vCPUs; its limit was outside the VM (virtio / host). A Distribution control without proxy mode or auth (`registry:2`, images pushed) reached 1113 MB/s at 2.86 vCPU — same cost class as proxy mode.

### 3.2 zot per-thread scaling (local, pinned)

| zot threads (CPUs) | Class | Saturated at | MB/s | pulls/s | p50 / p99 | zot CPU / cap |
|---|---|---:|---:|---:|---|---|
| 1 (4) | 10MB | 2 VUs | 2086 | 170 | 12 / 19 ms | 0.98 / 1 |
| 2 (4,6), separate cores | 10MB | 4 VUs | 4334 | 354 | 11 / 25 ms | 1.91 / 2 |
| 3 (4,6,8), separate cores | 10MB | 6 VUs | 6343 | 518 | 11 / 23 ms | 2.88 / 3 |
| 2 (4,5), HT siblings | 10MB | 2 VUs | 3079 | 252 | 8 / 13 ms | 1.93 / 2 |
| 1 (4) | 100MB | 1 VU | 2295 | 23.6 | 43 / 56 ms | 0.98 / 1 |
| 1 (4) | 1GB | 1 VU | 2537 | 2.7 | 356 / 659 ms | 0.99 / 1 |

Scaling 1.00× / 2.08× / 3.04×; a hyperthread sibling adds +48%; larger blobs cost ~10–30% less CPU per byte. zot RSS 162–168 MB; disk reads ≈ 0.

### 3.3 zot on EC2 (real NIC)

| Run | Class | VUs | MB/s | p50 / p99 | zot CPU | Note |
|---|---|---:|---:|---|---|---|
| No limit (GOMAXPROCS 8) | 10MB | 4 | 4960 | 10 / 15 ms | ~50% of 8 vCPU | **NIC full (39.8 Gbps)**; CPU 27% user / 73% kernel |
| GOMAXPROCS=1 | 10MB | 4 → 64 | 2661 → 2631 | 18/31 → 290/401 ms | 1.00 | flat throughput, linear queueing |
| GOMAXPROCS=1 | 100MB | 4 → 64 | 3461 → 3145 | 112/164 → 1968/2646 ms | 1.00 | |
| GOMAXPROCS=1 | 1GB | 4 → 64 | 3371 → 3305 | 1.1/1.4 → 17.1/23.9 s | 1.00 | |

Overloaded zot degrades gracefully: no errors, throughput flat, RSS +~15 MB from 1 to 64 VUs.

## 4. Why Harbor costs more

```
client ─► nginx ─► harbor-core ─► registry (Distribution v2.8.3, goharbor/registry-photon) ─► disk
                       └─ Postgres, Redis
```

| Container at saturation (345 MB/s, 28 pulls/s) | vCPU | Share | Disk writes |
|---|---:|---:|---|
| registry (Distribution) | 1.74 | 49% | 0 |
| harbor-core | 1.06 | 30% | 0 |
| nginx | 0.43 | 12% | 0 |
| harbor-db (Postgres) | 0.18 | 5% | 371 IOPS |
| redis + harbor-log | 0.17 | 5% | 0.5 MB/s |

| Cause | Evidence |
|---|---|
| Blob bytes cross 3 proxy hops | nginx `location /v2/ { proxy_pass http://core/v2/; }`; core streams from registry |
| 2 registry requests per blob | per 141 pulls: 917 `HEAD` + 917 `GET` blobs at the registry vs 917 blob GETs from clients |
| bcrypt auth on every internal request | registry `auth.htpasswd` (`$2y$05$`), no cache; ~390 checks/s at saturation (CPU share not profiled) |
| Verbose logging | 3 log lines per registry request, shipped via the `harbor-log` syslog container |
| DB writes per pull | per 216 pulls: `blob` +1360 updates (≈ 1 per blob), `audit_log_ext` +205 inserts (1 per pull) |
| Client round trips | per pull: 1 token + 2 manifest GETs (401, retry) + blobs = 9.5 requests for 10MB images |

Inside Harbor, Distribution costs ≈ 5 vCPU per GB/s vs ≈ 2 standalone. Possible tuning (untested): exclude pull events from the audit log, lower log levels. The proxy hops and per-blob `HEAD` are architectural.

zot (from source, v2.1.21): serves the blob file directly, but copies through a user buffer (`io.CopyN`, wrapped response writer without `ReaderFrom` → no `sendfile`); consistent with 73% kernel CPU, not confirmed by trace.

## 5. Sizing implications (warm serving, zot)

| Resource | Guidance |
|---|---|
| CPU | ~1 thread per 2 GB/s (16 Gbps) of peak egress, plus headroom → **2–4 cores** suffice for 10/25 GbE |
| NIC | First limit; size to the site's peak pull bandwidth |
| RAM | ~0.2 GB zot + **page cache ≥ hot image set** |
| Disk | Catalog capacity; throughput matters only when the hot set exceeds RAM (not measured) |
| HA | 2 active nodes per site; each sized to carry the peak alone |

Harbor needs roughly an order of magnitude more CPU for the same egress, plus a database with steady write load.

## 6. Limitations and open items

- Absolute numbers depend on CPU, network path and virtualisation (the VM inflates per-byte cost for all candidates); compare ratios.
- Shared, noisy dev host for local and VM runs (load average 3–6.6); single run per step; VM comparison used the 10MB class only.
- Distribution and Harbor were not CPU-profiled; the bcrypt share is an estimate.

| Not tested | Relevance | Known zot issues |
|---|---|---|
| Cold pulls (on-demand sync) | time-to-first-byte on cache miss | [#3463](https://github.com/project-zot/zot/issues/3463) (full image cached before serving); streaming [PR #3778](https://github.com/project-zot/zot/pull/3778) open |
| Concurrent first pulls across an HA pair | duplicate upstream fetches | [#4399](https://github.com/project-zot/zot/issues/4399), [#4215](https://github.com/project-zot/zot/issues/4215) |
| GC / retention under load | global store lock stalls requests | [#2964](https://github.com/project-zot/zot/issues/2964) (open) |
| Disk-bound serving, metadata polling, > 64 clients, failover | sizing edge cases | — |

## 7. Data and reproduction

- Design/plan: [`../superpowers/specs/`](../superpowers/specs/), [`../superpowers/plans/`](../superpowers/plans/)
- Data: [EC2 GOMAXPROCS=1](2026-09-29-zot-gomaxprocs1.md) · [EC2 no-limit smoke](2026-09-29-zot-ec2-no-limit-smoke/) · [local per-thread](2026-09-29-zot-local-per-thread.md) · [VM three-way + Harbor analysis](2026-10-03-vm-harbor-zot-distribution.md)
- Harness: EC2 `terraform/` + `scripts/run-suite.sh`; local `bench/local/` (`setup.sh`, `step.sh`); VM `bench/vm/` (`cloud-init.yaml`, `install-harbor.sh`, `step.sh`).
