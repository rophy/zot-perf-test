# Harbor vs zot vs Distribution — warm pulls in one VM

Date: 2026-10-03 · Consolidated findings: [`edge-cache-warm-throughput-report.md`](edge-cache-warm-throughput-report.md) · Step log: [`steps-log.md`](2026-10-03-vm-harbor-zot-distribution/steps-log.md) · Raw runs: [`runs/`](2026-10-03-vm-harbor-zot-distribution/runs/)

## Setup

- **VM:** multipass, Ubuntu 24.04, **4 vCPU (unpinned), 8 GiB**, on the i7-13620H dev host. Host ↔ VM virtio network measured at 31–33 Gbps (iperf3).
- **Registries** (one running at a time, same VM):
  - **Harbor v2.15.2** — online installer, plain HTTP, no Trivy; public **proxy-cache project** `proxy` → upstream registry on the host.
  - **zot v2.1.21** — container, same config as earlier tests (local storage, on-demand sync, `preserveDigest`, dedupe off, GC off).
  - **Distribution v3.1.2 (`registry:3`) in proxy mode** — `REGISTRY_PROXY_REMOTEURL` → upstream, defaults otherwise.
  - **Distribution `registry:2`** (v2.8.3, control) — images pushed directly (**not** proxy mode), no auth.
- **Upstream:** `registry:2` on the host holding the same 6 images/digests as earlier runs.
- **Load:** k6 on the host (unpinned), same pull model (manifest, then config + layers, 3 in parallel). For Harbor each pull also fetches an anonymous bearer token (as docker does).
- **Warm cache verified** for Harbor, zot and Distribution proxy: all blobs on disk, all images pullable with the upstream stopped, and **0 upstream requests** during the timed runs.
- **Metrics:** registry CPU = busy vCPUs of the whole VM (covers every Harbor container); memory = VM used (total − available); disk/network from the VM's node_exporter.
- 10MB class only; 40 s steps; single run per step. Host was busy (load average 3–6.6, other VMs and builds running).

## Results (10MB class)

| Registry | VUs | MB/s | pulls/s | p50 / p99 ms | VM vCPUs busy | VM mem MB | disk wr IOPS |
|---|---:|---:|---:|---|---:|---:|---:|
| Harbor | 1 | 169 | 13.8 | 70 / 115 | 2.32 / 4 | 1012 | 188 |
| Harbor | 2 | 239 | 19.5 | 101 / 154 | 2.93 / 4 | 888 | 261 |
| Harbor | 4 | 286 | 23.4 | 168 / 245 | 3.46 / 4 | 914 | 313 |
| Harbor | 8 | **334** | 27.2 | 293 / 395 | **3.77 / 4** | 966 | 353 |
| Distribution proxy | 1 | 818 | 66.8 | 14 / 31 | 2.11 / 4 | 734 | 5 |
| Distribution proxy | 2 | 981 | 80.1 | 23 / 48 | 2.54 / 4 | 733 | 4 |
| Distribution proxy | 4 | 1158 | 94.6 | 40 / 78 | 2.82 / 4 | 739 | 10 |
| Distribution proxy | 8 | 1403 | 114.6 | 67 / 126 | 3.02 / 4 | 745 | 10 |
| Distribution proxy | 16 | **1614** | 131.8 | 115 / 259 | 3.22 / 4 | 799 | 8 |
| Distribution control (no proxy) | 1 | 723 | 59.0 | 16 / 37 | 2.11 / 4 | 687 | 1 |
| Distribution control (no proxy) | 2 | 907 | 74.1 | 25 / 50 | 2.63 / 4 | 704 | 1 |
| Distribution control (no proxy) | 4 | 1113 | 90.9 | 42 / 78 | 2.86 / 4 | 699 | 1 |
| zot | 1 | 1229 | 100.3 | 9 / 22 | 1.32 / 4 | 697 | 9 |
| zot | 2 | 1464 | 119.5 | 16 / 35 | 1.52 / 4 | 701 | 1 |
| zot | 4 | 1679 | 137.1 | 28 / 56 | 1.59 / 4 | 706 | 1 |
| zot | 8 | 1978 | 161.5 | 46 / 107 | 1.76 / 4 | 712 | 1 |
| zot | 16 | **2210** | 180.5 | 83 / 203 | 1.90 / 4 | 737 | 1 |
| zot | 32 | 2200 | 179.7 | 154 / 471 | 1.94 / 4 | 787 | 1 |

Zero failed pulls everywhere.

| | Peak MB/s | Limited by | vCPUs per GB/s |
|---|---:|---|---:|
| zot | 2210 | not VM CPU (≈ 1.9 / 4 busy) — virtio/host path | ≈ 0.9 |
| Distribution proxy | 1614 | VM CPU nearly (3.2 / 4) | ≈ 2.0 |
| Distribution control (no auth, no proxy) | ≥ 1113 | not reached (4 VUs max) | ≈ 2.6 |
| Harbor (proxy cache) | 334 | VM CPU (3.8 / 4) | ≈ 11 |

## Harbor bottleneck analysis

Harbor is **Distribution plus a management/proxy layer**. Its `registry` container is the CNCF Distribution registry (`goharbor/registry-photon:v2.15.2`, `github.com/docker/distribution v2.8.3-35-g493dca9a`); clients never reach it directly.

```
client ─► nginx ─► harbor-core ─► registry (Distribution) ─► disk
                       └─ Postgres, Redis
```

**CPU by container at saturation** (8 VUs, 345 MB/s, 28 pulls/s, 268 client HTTP req/s; cgroup counters over 30 s):

| Container | Cores | Share | Disk writes |
|---|---:|---:|---|
| registry (Distribution) | 1.74 | 49% | 0 |
| harbor-core | 1.06 | 30% | 0 |
| nginx | 0.43 | 12% | 0 |
| harbor-db (Postgres) | 0.18 | 5% | 371 IOPS, 1.6 MB/s |
| redis | 0.11 | 3% | ~0 |
| harbor-log | 0.06 | 2% | 0.5 MB/s |

**Request fan-out per image pull** (141 pulls, 10MB class, 6.5 blobs/pull):

| Hop | Requests | Per pull |
|---|---:|---:|
| client → nginx | 1341 | 9.5 — 1 token, 2 manifest GETs (401 then retry), 6.5 blob GETs |
| harbor-core → registry | 1975 (5927 log lines) | 14 — **HEAD + GET for every blob**, plus the manifest |

**Why it costs ~12× zot's CPU per byte:**

1. **Blob bytes cross three proxy hops** — nginx routes `/v2/` to `core` (`proxy_pass http://core/v2/`), which streams from `registry`. zot serves the file directly.
2. **Distribution inside Harbor does ~2× plain Distribution's work per byte** (≈ 5 vs 2.6 vCPU per GB/s):
   - harbor-core's proxy-cache layer issues a **`HEAD` before each blob `GET`**;
   - the registry uses **`htpasswd` basic auth** (bcrypt, cost 5, `$2y$05$`) for core's internal account and **verifies it on every request** (no cache) — roughly 390 bcrypt checks/s at saturation (CPU share estimated, not profiled);
   - **3 log lines per request**, shipped through the `harbor-log` syslog container.
3. **harbor-core** reverse-proxies all bytes, runs proxy-cache checks, signs one token per pull and queries the DB.
4. **Postgres writes on every pull** (source of the disk IOPS): per 216 pulls, `blob` table 1360 updates (~1 per blob per pull), `audit_log_ext` 205 inserts (1 pull audit record per image), a few batched `artifact`/`repository` updates.

**Possible Harbor tuning (not tested):** exclude pull events from the audit log; lower registry/core log level. These reduce DB writes and logging; the proxy hops and per-blob `HEAD` are architectural.

## Caveats

- Absolute numbers are VM- and host-specific (virtio networking inside the guest is CPU-expensive: even Distribution needed ~2 vCPU for 0.7 GB/s). Compare ratios, not absolutes.
- zot did not saturate the VM's CPU, so its true per-vCPU ceiling is higher than shown.
- The Distribution control (`registry:2`) had no auth and no proxy mode; the proxy-mode run (`registry:3`) is the like-for-like pull-through comparison.
- Noisy shared host, unpinned VM, single run per step.
