# Edge Pull-Through Cache: Cold Pull, zot vs Distribution vs Harbor

| | |
|---|---|
| Date | 2026-10-04 |
| Question | What does a registry spend in CPU, memory and upstream traffic when it has to **fetch, verify, store and serve** an image it has never seen? |
| Candidates | zot v2.1.21 · Distribution v3.1.2 (proxy mode) · Harbor v2.15.2 (proxy-cache project) |
| Scope | Cold cache, whole-image pulls by digest, plain HTTP. Local, unthrottled upstream, so this measures software cost, not network behaviour. WAN, GC and HA failover were not tested. |
| Companion | Warm-cache serving: [warm throughput report](edge-cache-warm-throughput-report.md) |

## 1. Findings

1. **CPU per GB filled (same VM):**

   | Registry | 10 MB images | 100 MB images |
   |---|---:|---:|
   | zot | **9.2–9.5** | **5.9–6.3** |
   | Distribution | 13.5–15.8 | 5.8–6.6 |
   | Harbor | 58.9–83.7 | 11.0–16.0 |

   Filling the cache with small images costs about **10× (zot), 7× (Distribution) and 5–8× (Harbor)** what serving the same bytes warm costs. The cost per GB is stable across load steps for zot and Distribution (within ±10%) and varies for Harbor.
2. **Only zot deduplicates concurrent cold pulls.**
   - When 64 clients pull the same cold 1 GB image, zot fetches it from upstream once.
   - Distribution and Harbor fetch once per request, about **60× and 65×**.
   - Harbor fetches **2×** even for a single client: it streams one copy to the client and downloads a second copy into its cache.
3. **Memory:**
   - zot used 0.6–0.7 GB of VM memory and Distribution 0.6 GB.
   - Harbor peaked at **3.2–5.0 GB** filling 10 MB images and 1.0–1.9 GB filling 100 MB images.
   - With 64 clients on a 1 GB image, all three stayed between 0.8 and 1.2 GB.
4. **Harbor's cache is not complete when the pull finishes.**
   - Harbor writes the manifest from a background job that starts at least 20 s after the request, so an offline re-pull straight after a cold pull can fail even with one client.
   - With 64 clients on a 1 GB image, that background write gave up once (`MANIFEST_BLOB_UNKNOWN`). The image stayed uncached until another pull, which went to upstream again.
   - zot and Distribution always passed the offline re-pull.
5. **zot's default `http.writeTimeout` is 60 s.**
   - In one run of 64 clients on a 1 GB image, 15 clients were cut off with "unexpected EOF". The repeat run had none.
   - **Set `http.writeTimeout` explicitly for large images.** The same deadline applies to a manifest GET that is waiting for an on-demand sync, so a sync longer than 60 s would fail the client. That case is inferred from Go's `net/http` behaviour, not tested.
6. **Clients receive data at different times.**
   - zot holds every client until the whole image is synced, then serves from local disk.
   - Distribution and Harbor stream to clients immediately.
   - Pulling one 1 GB image took 7.4 s on zot, against 2.8 s on Distribution and 2.3 s on Harbor.
   - For 64 clients on a 1 GB image, the last client finished after 73–114 s on zot, 133–155 s on Distribution and 257–270 s on Harbor.
7. **Cold-fill throughput in this VM was limited by disk, not CPU.** The VM used less than 2 of its 4 cores, and MB/s swung between 16 and 250. The MB/s figures are therefore not a ranking of the registries.

## 2. Method

| | |
|---|---|
| Environment | multipass VM, Ubuntu 24.04, **4 vCPU (unpinned), 8 GiB**, on an i7-13620H dev host; the same VM and registry configs as the warm comparison; one registry running at a time |
| Upstream | `registry:2` on the host with synthetic single-arch images with random (incompressible) layers: **c10m** 400 × 10 MB, **c100m** 40 × 100 MB, **s100m** 16 × 100 MB, **s1g** 8 × 1 GB |
| Scenario A: unique pulls | k6 pulls every image in a class exactly once, each never seen before. Load rises 1, 2, 4, 8 … VUs until throughput gains less than 5%. Before each step the VM is restored to a snapshot with empty caches. |
| Scenario B: stampede | N = 1, 4, 16, 64 clients start together and pull the **same** cold image, using a fresh image per run. N = 16 and 64 were run twice. |
| Pull model | Same as the warm tests: manifest, then config and layers 3 at a time, by digest, with a bearer token for Harbor. Request timeout 600 s, no retries. |
| Measurement window | From k6 start until upstream traffic and VM disk writes have both stayed below 1 MB/s for 10 s. This is needed because each registry does its caching at a different time: zot before answering, Distribution while streaming, Harbor in the background afterwards. |
| CPU | Busy VM CPU-seconds, **excluding idle, steal and iowait**. iowait is recorded separately. |
| Checks | **Cold check:** upstream blob GETs ≥ unique blobs requested (passed on all 55 steps). **Offline check (Scenario B):** stop the upstream and pull the image once more. |
| Dedup factor | Bytes fetched from upstream ÷ image size. 1.00 means one upstream copy. |

## 3. Results

### 3.1 Scenario A: unique cold pulls (4 GB per step)

| Registry | Class | VUs tested | CPU-s/GB | VM cores | mem peak MB | dedup × | failed |
|---|---|---|---:|---:|---:|---:|---:|
| zot | c10m | 1, 2, 4 | 9.2–9.5 | 0.27–0.40 | 645–666 | 1.00 | 0 |
| zot | c100m | 1, 2 | 5.9–6.3 | 0.27–0.30 | 625–663 | 1.00 | 0 |
| Distribution | c10m | 1, 2, 4, 8 | 13.5–15.8 | 0.24–0.99 | 602–611 | 1.00 | 0 |
| Distribution | c100m | 1, 2, 4 | 5.8–6.6 | 0.19–0.72 | 577–584 | 1.00 | 0 |
| Harbor | c10m | 1, 2 | 58.9–83.7 | 1.54–1.81 | 3200–4987 | 1.96–2.00 | 0 |
| Harbor | c100m | 1, 2, 4, 8, 16 | 11.0–16.0 | 0.63–1.47 | 1026–1932 | 2.00 | 0 |

The warm reference from the same VM, 10 MB class, is zot ≈ 0.9, Distribution ≈ 2.0 and Harbor ≈ 11 CPU-s/GB. Warm figures count iowait as busy CPU, but warm iowait was only 0.1–0.5% of busy CPU, so the comparison holds.

### 3.2 Scenario B: stampede, N = 64 (two runs each)

| Registry | Class | Time to last client | VM CPU-s | mem peak MB | dedup × | failed | offline check |
|---|---|---|---:|---:|---:|---:|---|
| zot | s100m | 11 / 8 s | 11 / 8 | 1041 / 1054 | 1.00 | 0 | ok |
| zot | s1g | 114 / 73 s | 118 / 80 | 1137 / 1138 | 1.00 | 15 / 0 | ok |
| Distribution | s100m | 11 / 7 s | 13 / 10 | 691 / 800 | 53.0 / 22.8 | 0 | ok |
| Distribution | s1g | 155 / 133 s | 162 / 142 | 770 / 797 | 62.1 / 60.1 | 0 | ok |
| Harbor | s100m | 25 / 25 s | 42 / 42 | 1085 / 1101 | 65.9 / 65.7 | 0 | FAIL |
| Harbor | s1g | 270 / 257 s | 432 / 422 | 1202 / 1182 | 65.2 / 65.2 | 0 | FAIL |

At N = 1, dedup was 1.00 for zot and Distribution and 2.00 for Harbor. Rows for all N values are in the [detailed results](2026-10-04-cold-pull.md).

## 4. Why they differ

| Registry | Cold path (source, at the version tested) | Effect |
|---|---|---|
| zot | A manifest GET triggers `SyncImage`, which runs one upstream sync per repo and reference (`singleflight`, `pkg/extensions/sync/on_demand.go`). It answers only after the whole image is stored. | One upstream fetch however many clients ask. All clients wait for the full sync. |
| Distribution | The proxy streams each blob from upstream to the client while writing it to storage. | Data reaches clients immediately. Each concurrent request makes its own upstream fetch. |
| Harbor | On a local miss, `ProxyBlob` streams from upstream to the client **and** starts a separate background download into storage (`src/controller/proxy/controller.go:285`). The manifest is pushed by a background job that sleeps 20 s, then waits up to 10 × 20 s for the blobs (`manifestcache.go:190-217`). | 2× upstream traffic per request and no deduplication. The cache is complete only after the deferred manifest push, which can give up under heavy load. |

## 5. Implications for zot at the edge

| Topic | Guidance |
|---|---|
| CPU for cache fill | ≈ 6–10 CPU-s per GB fetched, on top of warm serving. These are VM-measured figures, so absolute values are inflated. |
| Upstream traffic | Concurrent first pulls of an image cost one upstream fetch per node. An active/standby pair fetches at most twice per site. |
| Config | Set `http.writeTimeout` explicitly; the 60 s default cuts large or slow transfers. |
| Large cold images | Clients get no data until the whole image is synced, so client or ingress timeouts can trigger. This is accepted until upstream streaming lands ([#4323](https://github.com/project-zot/zot/issues/4323), [PR #3778](https://github.com/project-zot/zot/pull/3778)). |

## 6. Limitations and open items

- The host was shared and noisy, and the VM inflates absolute CPU cost, so compare ratios. Scenario A throughput was set by host disk I/O.
- Each step ran once, except Scenario B at N = 16 and 64, which ran twice.
- Synthetic images came from a local upstream, with no WAN latency, throttling or TLS.
- Memory is VM used memory, which includes the OS. Harbor's figure covers all its containers.
- These were observed in-session and are not archived in the repo:
  - Harbor's `core.log` counts of `MANIFEST_BLOB_UNKNOWN` (36 and 28);
  - the later offline re-check, in which 11 of 12 Harbor images were pullable.
- The causes in section 4 come from source reading plus logs, not from patched re-runs.

| Not tested | Relevance |
|---|---|
| Cold pulls over a WAN | Time to first byte and total pull time with real latency and bandwidth limits |
| GC during cold pulls | zot [#2964](https://github.com/project-zot/zot/issues/2964) (global store lock) and [#4399](https://github.com/project-zot/zot/issues/4399) (fix in v2.1.21) |
| Failover to a cold standby | Burst of cold pulls after HA failover |

## 7. Data and reproduction

- Design and plan: [spec](../superpowers/specs/2026-10-04-cold-pull-design.md), [plan](../superpowers/plans/2026-10-04-cold-pull.md)
- Detailed results (all 55 steps, per-row findings): [2026-10-04-cold-pull.md](2026-10-04-cold-pull.md); step log and raw runs in [`2026-10-04-cold-pull/`](2026-10-04-cold-pull/)
- Harness:
  - `images/gen_synthetic.py` builds the image pool;
  - `k6/cold.js` drives the pulls;
  - `bench/vm/cold-vm.sh` and `bench/vm/cold-step.sh` take the snapshot and run each step;
  - `scripts/coldstep.py` and `scripts/coldlib.py` collect and analyse.
