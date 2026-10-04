# Cold-Pull Cost Benchmark (zot vs Distribution vs Harbor): Design

Date: 2026-10-04
Status: Draft (pending review)

## Context

Phase 1 measured warm-cache serving ([report](../../results/edge-cache-warm-throughput-report.md)). zot was chosen for the edge, with each site running two standalone nodes (local disk, active/standby). This phase measures the **CPU and memory cost of cold work**: fetching from upstream, verifying, writing to disk, and serving. It compares the same three candidates as phase 1.

The question is about software resource cost, **not** about network behaviour. The upstream is local and unthrottled.

## Goals

1. CPU-seconds per GB and memory for steady cache fill, where every pull is a never-seen image (Scenario A).
2. Cost and upstream deduplication when N clients pull the same cold image at once (Scenario B).
3. Pull latency and errors under both scenarios, recorded as results.

## Out of scope

- WAN and network shaping
- GC and retention
- HA failover
- TLS (terminated at the ingress)
- Tag-based pulls: all pulls are by digest

## Environment

Same as the phase-1 VM comparison (`bench/vm/`):
- multipass VM, Ubuntu 24.04, 4 vCPU (unpinned), 8 GiB, on the i7-13620H host.
- Only one registry runs at a time:
  - **zot v2.1.21**, with the same config as phase 1 (on-demand sync, `preserveDigest`, dedupe off, GC off);
  - **Distribution v3.1.2** (`registry:3`) in proxy mode;
  - **Harbor v2.15.2** with a proxy-cache project.
- **Upstream:** `registry:2` on the host. Images are stored on the host's internal disk.
- **Load:** k6 on the host, using the same pull model as `k6/pull.js` (manifest, then config and layers, 3 in parallel, `Content-Length` checked, bearer token for Harbor). The request timeout is 10 min.
- **Metrics:** Prometheus and node_exporter (VM-wide CPU, memory, disk, network), plus the upstream counters below.

## Test images

All images are synthetic, single-arch, with layers of random (incompressible) data. They are generated once and pushed to the upstream.

| Class | Count | Layers | Image size | Use |
|---|---:|---:|---:|---|
| c10m | 400 | 4 × 2.5 MB | 10 MB | Scenario A |
| c100m | 40 | 4 × 25 MB | 100 MB | Scenario A |
| s100m | 16 | 4 × 25 MB | 100 MB | Scenario B, 1 per run |
| s1g | 8 | 8 × 128 MB | 1 GB | Scenario B, 1 per run |

The upstream totals about 18 GB, within the host's 55 GB free. Repos are named `cold/<class>-NNN`. The generator also writes `images/cold.json`, which records the repo, digest, size and blobs for each image, in the same shape as `images.json`.

## Scenario A: unique cold pulls

- Each step is a fixed amount of work, not a fixed duration: the whole class pool (400 or 40 images) is pulled exactly once. VUs take the next image from a shared counter (`exec.scenario.iterationInTest`), using a `shared-iterations` executor with iterations equal to the pool size.
- VU steps are 1, 2, 4, 8, … for each class. Stop when VM CPU saturates (at least 95% of 4 vCPU) or throughput stops rising, one set at a time as in phase 1.
- Before each step the VM is reset to `cold-base` (see Reset), so every pull is cold.
- The VM holds at most about 4 GB of cached data per step.

## Scenario B: stampede

- N = 1, 4, 16 and 64 VUs, `per-vu-iterations` with 1 iteration each. All VUs start at the same time and pull the **same** image.
- Classes are s100m and s1g, with a fresh image per run, so no reset is needed between runs. Reset only when switching registries, or if VM disk use goes above 15 GB.
- N = 16 and N = 64 are run twice.

## Reset

- **Prepare once:** install all three registries in the VM, leave them stopped with empty caches, and configure Harbor's proxy-cache project with no artifacts. Then take the multipass snapshot `cold-base`.
- **Per step (Scenario A), or per registry (Scenario B):**
  1. Stop the VM.
  2. Restore `cold-base`.
  3. Start the VM.
  4. Start the one registry under test.
  5. Wait for its health endpoint.

## Measurement window

The three registries do cold work at different times:
- zot syncs before it responds.
- Distribution writes to disk while streaming to the client.
- Harbor caches blobs and manifests in background goroutines after responding.

So each step's window runs **from the k6 start until upstream transmit traffic and VM disk writes have both been below 1 MB/s for 10 s**, capped at 15 min. CPU-seconds and averages are computed over this window. The k6 duration is reported separately.

## Metrics per step

| Metric | Source |
|---|---|
| Throughput (MB/s served) | k6, over the k6 duration |
| p50 / p99 pull time, errors by type | k6 summary |
| VM CPU-seconds (total, and per GB served) | node_exporter, over the window |
| VM memory used (peak and average), registry RSS | node_exporter; process or cgroup RSS |
| VM disk write MB/s and IOPS | node_exporter |
| Upstream bytes sent, upstream blob GETs | upstream container veth counters before and after; upstream access log |
| Deduplication factor (Scenario B) | upstream blob bytes ÷ image size |
| Wait-until-quiet tail | window end − k6 end |

## Validity checks

- **Cold:** upstream blob GETs in the step must be at least the number of unique blobs requested. Otherwise the step is invalid.
- **Integrity:** k6 checks `Content-Length`. After each Scenario B run, the image is pulled once with the upstream **stopped**, which must succeed.
- **Load generator:** k6 CPU stays below 70%. Host load average is recorded.
- **Errors:** recorded, not retried. Timeouts and 5xx count as results, not as harness failures.

## Components

| Path | Purpose |
|---|---|
| `images/gen-synthetic.sh` | Generates and pushes the synthetic images, and writes `images/cold.json` |
| `k6/cold.js` | Scenario A and B (selected by env var), reusing `k6/lib/select.js` and the token flow |
| `bench/vm/cold-prepare.sh` | Brings the registries to the empty, stopped state and takes the `cold-base` snapshot |
| `bench/vm/cold-step.sh` | Runs one step (restore, start, k6, wait until quiet, collect, append to the step log) |
| `scripts/` | Window and metric queries, added to `benchlib.py` with unit tests |

## Outputs

- `docs/results/<date>-cold-pull/`, containing the step log and `runs/` (k6 summaries and Prometheus exports).
- A results doc, then a "Cold pull" section in the main report.

## Risks

- **Harbor background caching** extends work past the k6 end. This is covered by the measurement window.
- **zot 1GB stampede:** all clients wait for the full sync. A local upstream should finish well within the 10 min timeout.
- **Snapshot restore** leaves a cold page cache in the VM. This is the same for all three registries and small compared with the data volume.
- **Noisy shared host, single run per step**, except N = 16 and 64 in Scenario B, which run twice.
