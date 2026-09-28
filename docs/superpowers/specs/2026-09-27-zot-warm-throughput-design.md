# Zot Warm-Cache Throughput Benchmark — Design

Date: 2026-09-27
Status: Draft (pending review)

## Context

Target architecture: one source registry, many regional edge sites running a
pull-through cache. Each edge site is HA as 2 independent active instances
behind a load balancer (no shared state). Zot is the primary candidate; Harbor
comparison is deferred.

This is phase 1: **single-node, warm-cache pull throughput** of Zot.

Out of scope for this phase (later phases):
- Cold-pull / on-demand sync performance
- GC and global image-store lock contention (zot issue #2964)
- HA pair behind LB, failover
- Cross-region / WAN simulation
- TLS (phase 1 uses plain HTTP; TLS is a follow-up scenario)
- Harbor

## Goals

1. Throughput-vs-concurrency curve per image size class (10MB / 100MB / 1GB).
2. Per-image pull latency (p50/p95/p99/max) at each concurrency step.
3. Identify the first saturated resource at each step: zot CPU, zot NIC, or client.
4. Resource footprint of zot under load (CPU, RSS).

## Environment

- AWS credentials from the default credential chain, region `us-east-1`, single AZ, cluster placement group.
- **zot node**: `m6idn.2xlarge` (Intel Ice Lake 3.5GHz, 8 vCPU / 4 cores,
  32 GiB, 474GB NVMe, 12.5 Gbps baseline / 40 Gbps burst network).
  - NVMe formatted XFS, mounted at `/var/lib/zot`.
  - IAM instance profile with `AmazonEC2ContainerRegistryReadOnly`.
- **client node**: `m6idn.2xlarge` — runs k6 and Prometheus.
- OS: Amazon Linux 2023 on both; identical sysctl network tuning (TCP buffers,
  `somaxconn`).
- Security group: zot port 5000 only from client; SSH only from operator IP;
  node_exporter port only from client.
- Provisioned with Terraform (`infra/`, local state). Teardown via
  `terraform destroy`.

## Source registry: ECR

- 6 public images copied to ECR under `bench/*`, pinned by digest, linux/amd64
  only (`crane copy --platform linux/amd64`).
- `images/preload.sh` writes `images/images.json` (ECR ref, digest, total
  compressed size, layer count) consumed by k6.

| Class  | Image                          | Compressed | Layers | Largest layer |
|--------|--------------------------------|-----------:|-------:|--------------:|
| 10MB   | `registry:2`                   | 10 MB      | 5      | 6 MB          |
| 10MB   | `haproxy:3.0-alpine`           | 14 MB      | 6      | 10 MB         |
| 100MB  | `eclipse-temurin:21-jre`       | 115 MB     | 6      | 53 MB         |
| 100MB  | `node:22-slim`                 | 80 MB      | 5      | —             |
| 1GB    | `selenium/standalone-chrome`   | 1004 MB    | 38     | 221 MB        |
| 1GB    | `sonarqube:10-community`       | 856 MB     | 8      | 764 MB        |

Sizes measured 2026-09-27 via `crane manifest`; actual digests are pinned in
`images/images.txt` at preload time.

## Zot deployment

- zot **v2.1.21** binary under systemd (no container, to avoid network overhead).
- Config:
  - `storage.rootDirectory: /var/lib/zot`, local driver, `dedupe: false`,
    GC disabled.
  - `extensions.sync`: one registry = ECR URL, `onDemand: true`,
    `credentialHelper: "ecr"`.
  - `extensions.metrics` enabled (`/metrics`).
  - Auth disabled, plain HTTP on port 5000.
- `GOMEMLIMIT` set explicitly (e.g. 24GiB) in the systemd unit.

## Monitoring

- `node_exporter` on both nodes.
- Prometheus on the client node scraping: zot `/metrics`, zot node_exporter,
  client node_exporter (5s interval).
- k6 pushes metrics to the same Prometheus via remote write
  (`--out experimental-prometheus-rw`) for a unified timeline.

## Load test (k6)

### Pull model (`k6/pull.js`)

Each iteration, per VU:
1. `GET /v2/<repo>/manifests/<digest>` with OCI/Docker manifest Accept headers;
   parse layer + config descriptors.
2. `http.batch()` GET all blobs (config + layers) in parallel.
3. Record custom `Trend` `image_pull_duration` (start of manifest GET → last
   blob complete), `Counter` `image_pulls`, tagged by `size_class` and `image`.

`discardResponseBodies: true` globally (manifest request opts back in with
`responseType: 'text'`). Blob digests are not verified client-side in k6
(correctness is checked once by `warmup.sh` using `crane`).

### Warm-up (`scripts/warmup.sh`)

- `crane pull` each image through zot once (triggers on-demand sync).
- Verify: every blob present under `/var/lib/zot`, and a second pull produces no
  new sync activity in zot logs/metrics.
- Timed runs must never hit ECR.

### Scenarios (`scripts/run-suite.sh`)

- **Per size class** (10MB, 100MB, 1GB): VUs loop over the class's 2 images.
  Concurrency ladder `1 → 4 → 16 → 64 → 128 → 256` VUs, 60s per step, 10s gap.
  Each step is a separate k6 invocation (clean per-step summaries).
- **Mixed**: weighted 70% 10MB / 25% 100MB / 5% 1GB at the concurrency where the
  per-class runs saturated.
- **Page-cache variants**:
  - (a) page-cache warm (default, all runs).
  - (b) disk-warm: `sync; echo 3 > /proc/sys/vm/drop_caches` on zot node before
    each step; run once for the 1GB class.
- Every run repeated **3 times**; report median and spread.

### Stop / validity rules

- k6 thresholds abort a step: error rate > 1% or `image_pull_duration` p99 > 30s.
  The ladder stops; the last passing step is recorded as saturation point.
- Remaining ladder steps for a class are skipped once zot NIC is at the
  12.5 Gbps baseline for a full step (further VUs only add queueing).
- A step is flagged **invalid** if client CPU > 70% average during the step.

## Metrics collected per step

- k6: image pulls/s, `image_pull_duration` p50/p95/p99/max, `http_req_duration`
  for manifests and blobs, `data_received` rate, error rate.
- zot node: CPU %, RSS, NIC rx/tx bytes/s, disk read MB/s, zot HTTP metrics,
  `storage_lock_latency_seconds`.
- client node: CPU %, NIC rx bytes/s.

## Repo layout

```
ccdn/
├── infra/                 # Terraform
├── zot/                   # config.json, zot.service, install.sh
├── images/                # images.txt, preload.sh → images.json
├── k6/                    # pull.js, lib/
├── monitoring/            # prometheus.yml, node_exporter setup
├── scripts/               # warmup.sh, run-suite.sh, collect.sh
├── results/<timestamp>/   # k6 HTML + summary JSON, prom snapshot, env.json, report.md
└── docs/superpowers/specs/
```

## Run flow

1. `terraform apply`
2. Install zot + node_exporter (zot node), k6 + Prometheus + node_exporter
   (client) via user-data / install scripts.
3. `images/preload.sh` (run from operator machine).
4. `scripts/warmup.sh`
5. `scripts/run-suite.sh`
6. `scripts/collect.sh` → `results/<timestamp>/` (includes `env.json`: instance
   types, kernel, zot version, zot config hash, image digests).
7. `terraform destroy`

## Report

`results/<timestamp>/report.md`:
- Per size class: table + chart of pulls/s and MB/s vs VUs, p50/p99 pull time
  vs VUs.
- Saturation annotation per step (zot CPU / zot NIC / client / none).
- zot CPU and RSS vs load.
- Mixed-workload results.
- Page-cache vs disk-warm comparison for 1GB.

## Cost estimate

2 × m6idn.2xlarge ≈ $1.27/h on-demand. ECR same-region transfer free; storage
~2GB ≈ $0.20/month. A one-day run ≈ $10–15.

## Risks / open items

- k6 throughput at ~12.5 Gbps on 4 physical cores is unverified; validity rule
  (client CPU ≤ 70%) catches it. Mitigation: add a second client node.
- ECR performance only affects warm-up, not timed runs.
- Image tags like `selenium/standalone-chrome:latest` drift upstream; pinning by
  digest at preload time fixes the benchmark set.
