# Zot Warm-Cache Throughput Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and run a reproducible benchmark measuring single-node zot v2.1.21 warm-cache pull throughput on EC2 (m6idn.2xlarge) with k6, sourcing images from ECR.

**Architecture:** Everything is developed and tested first against a local docker-compose harness (upstream `registry:2` + zot + Prometheus), then deployed to EC2 with Terraform. An operator machine orchestrates the suite over SSH: it runs one k6 invocation per concurrency step on the client node, and a Python report tool queries Prometheus (through an SSH tunnel) per step window to annotate saturation and validity.

**Tech Stack:** Terraform 1.14 (AWS provider ~> 6.0), zot v2.1.21, k6 v2.3.0, Prometheus v3.15.0, node_exporter v1.12.1, crane (go-containerregistry), Python 3 stdlib + pytest, bash, docker compose.

**Spec:** `docs/superpowers/specs/2026-09-27-zot-warm-throughput-design.md`

## Global Constraints

- AWS credentials from the default credential chain, region `us-east-1`; single AZ `us-east-1a`; cluster placement group.
- zot node and client node: `m6idn.2xlarge`; Amazon Linux 2023 x86_64.
- zot **v2.1.21** binary (`zot-linux-amd64`, full build — metrics extension needs it) under systemd, plain HTTP, port 5000, local storage at `/var/lib/zot` on the instance NVMe (XFS), `dedupe: false`, `gc: false`.
- Sync: on-demand from ECR, `credentialHelper: "ecr"`, `preserveDigest: true`.
- k6 **v2.3.0**; Prometheus **v3.15.0** on client node; node_exporter **v1.12.1** on both nodes.
- Images: the 6 images in the spec, linux/amd64 only, in ECR repos `bench/*`, tag `bench`, pulled by **digest** during timed runs.
- Concurrency ladder `1 4 16 64 128 256`, 60s per step, 10s gap, 3 repeats.
- Abort step: `image_pull_failed` rate > 1% or `image_pull_duration` p99 > 30s. Invalid step: client CPU avg > 70%. Stop ladder when zot NIC tx ≥ 95% of 12.5 Gbps.
- Commit messages: `<type>: <description>`, no mention of Claude, no Co-Authored-By line.
- No private domains in committed files.

## Design decisions made while planning (not in spec — review)

1. **Pull by digest + `preserveDigest: true`.** Pulling by tag makes zot re-check upstream per pull (zot issue #4393), which would hit ECR during timed runs. Digests are immutable, so zot serves from cache. `preserveDigest` prevents zot converting Docker manifests to OCI (which would change digests).
2. **Layer parallelism = 3 per pull** (`LAYER_PARALLELISM` env, default 3), matching docker/containerd default max concurrent downloads. Spec said "all layers in parallel"; 3 is closer to real clients. Configurable.
3. **Operator-driven orchestration.** `run-suite.sh` runs on the operator machine and drives both nodes over SSH (needed for `drop_caches` on the zot node). Each step is ≤ ~75s, so SSH session length is not a concern.
4. **Default VPC** (exists in account) and a default subnet in `us-east-1a`; no custom VPC.
5. **k6 HTML report** via `--out web-dashboard` with `K6_WEB_DASHBOARD_EXPORT` (verified on k6 v2.3.0; skipped for runs < ~20s).

## File Structure

```
ccdn/
├── .gitignore
├── README.md                      # how to run (local + EC2)
├── images/
│   ├── images.txt                 # class, source ref, dest repo
│   ├── describe.py                # registry → images.json (digest, size, layers)
│   ├── test_describe.py
│   └── preload.sh                 # create ECR repos, crane copy, write images.json
├── zot/
│   ├── render-config.sh           # jq-rendered zot config.json
│   └── zot.service                # systemd unit
├── k6/
│   ├── pull.js                    # k6 entrypoint
│   └── lib/
│       ├── select.js              # pure selection/manifest logic
│       └── select.test.mjs        # node --test
├── scripts/
│   ├── benchlib.py                # summary parsing, prom queries, verdicts
│   ├── test_benchlib.py
│   ├── report.py                  # results dir → report.md
│   ├── stepcheck.py               # post-step: should the ladder stop?
│   ├── warmup.sh                  # pull all images through zot + verify cached
│   ├── run-suite.sh               # ladder × classes × repeats
│   └── collect-env.sh             # env.json
├── test/local/
│   ├── compose.yaml               # upstream registry + zot + prometheus
│   ├── prometheus.yml
│   ├── images.txt                 # local synthetic images
│   ├── seed.sh                    # push synthetic images to upstream
│   └── e2e.sh                     # full local smoke test
├── monitoring/
│   └── prometheus.yml.tpl         # EC2 client Prometheus config
└── infra/
    ├── versions.tf
    ├── variables.tf
    ├── main.tf
    ├── outputs.tf
    ├── userdata-zot.sh.tpl
    └── userdata-client.sh.tpl
```

**Shared data contract — `images.json`** (produced by `images/describe.py`, consumed by k6, warmup, report):

```json
{
  "images": [
    {"class": "10MB", "repo": "bench/registry", "digest": "sha256:…", "size": 10123456, "layers": 5}
  ]
}
```
`size` = sum of config + layer compressed sizes (bytes). `layers` = number of layer descriptors (config excluded).

**Results directory contract** (`results/<ts>/`, produced by `run-suite.sh`):
- `steps.csv`: header `run_id,class,vus,repeat,start_epoch,end_epoch,exit_code,drop_caches`
- `<run_id>.summary.json`: k6 `--summary-export` output
- `<run_id>.html`: k6 dashboard export
- `<run_id>.log`: k6 stdout/stderr
- `env.json`, `images.json`, `report.md`

`run_id` format: `<class>-v<vus>-r<repeat>[-dc]` e.g. `100MB-v16-r2`, `1GB-v4-r1-dc`.

---

### Task 1: Repo scaffold + image catalog (`describe.py`)

**Files:**
- Create: `.gitignore`, `images/images.txt`, `images/describe.py`, `images/test_describe.py`

**Interfaces:**
- Produces: `python3 images/describe.py --registry <host[:port]> --tag <tag> [--insecure] <images.txt>` → prints `images.json` to stdout.
- Produces (Python): `parse_images_txt(text: str) -> list[dict]` with keys `class, src, repo`; `describe_manifest(manifest_bytes: bytes) -> dict` with keys `digest, size, layers`.

- [ ] **Step 1: Create `.gitignore`**

```gitignore
results/
infra/.terraform/
infra/.terraform.lock.hcl
infra/terraform.tfstate*
infra/.ssh/
terraform/app/ssh_config
images/images.json
test/local/images.json
test/local/results/
test/local/zot-config.json
test/local/k6-smoke.json
__pycache__/
```

- [ ] **Step 2: Create `images/images.txt`**

```
# class  source-ref                                      dest-repo
10MB   docker.io/library/registry:2                     bench/registry
10MB   docker.io/library/haproxy:3.0-alpine             bench/haproxy
100MB  docker.io/library/eclipse-temurin:21-jre         bench/eclipse-temurin
100MB  docker.io/library/node:22-slim                   bench/node
1GB    docker.io/selenium/standalone-chrome:latest      bench/standalone-chrome
1GB    docker.io/library/sonarqube:10-community         bench/sonarqube
```

- [ ] **Step 3: Write failing tests `images/test_describe.py`**

```python
import hashlib
import json

import pytest

from describe import describe_manifest, parse_images_txt


def test_parse_images_txt_skips_comments_and_blanks():
    text = "# c s r\n\n10MB  docker.io/library/registry:2  bench/registry\n1GB a/b:c bench/b\n"
    assert parse_images_txt(text) == [
        {"class": "10MB", "src": "docker.io/library/registry:2", "repo": "bench/registry"},
        {"class": "1GB", "src": "a/b:c", "repo": "bench/b"},
    ]


def test_parse_images_txt_rejects_bad_class():
    with pytest.raises(ValueError, match="class"):
        parse_images_txt("5MB a/b:c bench/b\n")


def test_parse_images_txt_rejects_wrong_field_count():
    with pytest.raises(ValueError, match="3 fields"):
        parse_images_txt("10MB a/b:c\n")


def test_describe_manifest():
    manifest = {
        "schemaVersion": 2,
        "config": {"digest": "sha256:c", "size": 100},
        "layers": [{"digest": "sha256:l1", "size": 1000}, {"digest": "sha256:l2", "size": 2000}],
    }
    raw = json.dumps(manifest).encode()
    got = describe_manifest(raw)
    assert got == {"digest": "sha256:" + hashlib.sha256(raw).hexdigest(), "size": 3100, "layers": 2}


def test_describe_manifest_rejects_index():
    raw = json.dumps({"schemaVersion": 2, "manifests": []}).encode()
    with pytest.raises(ValueError, match="index"):
        describe_manifest(raw)
```

- [ ] **Step 4: Run tests, verify they fail**

Run: `cd images && python3 -m pytest -q test_describe.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'describe'`

- [ ] **Step 5: Implement `images/describe.py`**

```python
#!/usr/bin/env python3
"""Build images.json from images.txt by reading manifests from a registry via crane."""
import argparse
import hashlib
import json
import subprocess
import sys

CLASSES = ("10MB", "100MB", "1GB")


def parse_images_txt(text):
    entries = []
    for lineno, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) != 3:
            raise ValueError(f"line {lineno}: expected 3 fields, got {len(fields)}")
        cls, src, repo = fields
        if cls not in CLASSES:
            raise ValueError(f"line {lineno}: unknown class {cls!r}")
        entries.append({"class": cls, "src": src, "repo": repo})
    return entries


def describe_manifest(raw):
    manifest = json.loads(raw)
    if "manifests" in manifest:
        raise ValueError("got an image index; expected a single-platform manifest")
    layers = manifest["layers"]
    size = manifest["config"]["size"] + sum(layer["size"] for layer in layers)
    return {"digest": "sha256:" + hashlib.sha256(raw).hexdigest(), "size": size, "layers": len(layers)}


def fetch_manifest(ref, insecure):
    cmd = ["crane", "manifest", ref]
    if insecure:
        cmd.insert(1, "--insecure")
    return subprocess.run(cmd, check=True, capture_output=True).stdout


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--registry", required=True)
    ap.add_argument("--tag", default="bench")
    ap.add_argument("--insecure", action="store_true")
    ap.add_argument("images_txt")
    args = ap.parse_args(argv)

    with open(args.images_txt) as f:
        entries = parse_images_txt(f.read())
    out = []
    for e in entries:
        raw = fetch_manifest(f"{args.registry}/{e['repo']}:{args.tag}", args.insecure)
        out.append({"class": e["class"], "repo": e["repo"], **describe_manifest(raw)})
    json.dump({"images": out}, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
```

- [ ] **Step 6: Run tests, verify they pass**

Run: `cd images && python3 -m pytest -q test_describe.py`
Expected: `5 passed`

- [ ] **Step 7: Commit**

```bash
git add .gitignore images/images.txt images/describe.py images/test_describe.py
git commit -m "feat: add image catalog and images.json generator"
```

---

### Task 2: zot config renderer + local test harness

**Files:**
- Create: `zot/render-config.sh`, `test/local/compose.yaml`, `test/local/prometheus.yml`, `test/local/images.txt`, `test/local/seed.sh`

**Interfaces:**
- Produces: `zot/render-config.sh` — env in: `UPSTREAM_URL` (required), `ROOT_DIR` (default `/var/lib/zot`), `PORT` (default `5000`), `TLS_VERIFY` (default `true`), `CREDENTIAL_HELPER` (default empty). Prints zot config JSON to stdout.
- Produces: local stack — upstream registry at `localhost:5001`, zot at `localhost:5000`, Prometheus at `localhost:9090` (remote-write receiver enabled). Docker network hostnames: `upstream`, `zot`.
- Produces: `test/local/seed.sh` — pushes 3 synthetic single-platform images (tag `bench`) to `localhost:5001`, then writes `test/local/images.json` via `images/describe.py`.

- [ ] **Step 1: Write `zot/render-config.sh`**

```bash
#!/usr/bin/env bash
# Render zot config.json for a pull-through cache. Output to stdout.
set -euo pipefail
: "${UPSTREAM_URL:?UPSTREAM_URL is required}"
ROOT_DIR="${ROOT_DIR:-/var/lib/zot}"
PORT="${PORT:-5000}"
TLS_VERIFY="${TLS_VERIFY:-true}"
CREDENTIAL_HELPER="${CREDENTIAL_HELPER:-}"

jq -n \
  --arg root "$ROOT_DIR" --arg port "$PORT" --arg url "$UPSTREAM_URL" \
  --argjson tls "$TLS_VERIFY" --arg helper "$CREDENTIAL_HELPER" '
{
  distSpecVersion: "1.1.1",
  storage: { rootDirectory: $root, dedupe: false, gc: false },
  http: { address: "0.0.0.0", port: $port },
  log: { level: "info" },
  extensions: {
    metrics: { enable: true, prometheus: { path: "/metrics" } },
    sync: {
      enable: true,
      downloadDir: ($root + "/.sync-download"),
      registries: [
        ({ urls: [$url], onDemand: true, tlsVerify: $tls, preserveDigest: true,
           maxRetries: 3, retryDelay: "10s" }
         + (if $helper == "" then {} else { credentialHelper: $helper } end))
      ]
    }
  }
}'
```

Run: `chmod +x zot/render-config.sh && UPSTREAM_URL=http://upstream:5000 TLS_VERIFY=false zot/render-config.sh | jq -e '.extensions.sync.registries[0].preserveDigest == true and (.extensions.sync.registries[0] | has("credentialHelper") | not)'`
Expected: `true`

Run: `UPSTREAM_URL=https://1.dkr.ecr.us-east-1.amazonaws.com CREDENTIAL_HELPER=ecr zot/render-config.sh | jq -r '.extensions.sync.registries[0].credentialHelper'`
Expected: `ecr`

- [ ] **Step 2: Write `test/local/compose.yaml`**

```yaml
name: ccdn-local
services:
  upstream:
    image: registry:2
    ports: ["5001:5000"]
  zot:
    image: ghcr.io/project-zot/zot-linux-amd64:v2.1.21
    command: ["serve", "/etc/zot/config.json"]
    volumes:
      - ./zot-config.json:/etc/zot/config.json:ro
      - zot-data:/var/lib/zot
    ports: ["5000:5000"]
    depends_on: [upstream]
  prometheus:
    image: prom/prometheus:v3.15.0
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --web.enable-remote-write-receiver
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
    ports: ["9090:9090"]
volumes:
  zot-data:
```

- [ ] **Step 3: Write `test/local/prometheus.yml`**

```yaml
global:
  scrape_interval: 5s
scrape_configs:
  - job_name: zot
    static_configs:
      - targets: ["zot:5000"]
```

- [ ] **Step 4: Write `test/local/images.txt`**

```
10MB   synthetic   bench/small
100MB  synthetic   bench/medium
1GB    synthetic   bench/large
```

(Local "sizes" are scaled down: 2MB / 8MB / 32MB, 3 layers each. Class labels are kept so k6 class filtering is exercised.)

- [ ] **Step 5: Write `test/local/seed.sh`**

```bash
#!/usr/bin/env bash
# Push 3 synthetic images to the local upstream registry and write images.json.
set -euo pipefail
cd "$(dirname "$0")"
UPSTREAM="${UPSTREAM:-localhost:5001}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

push_image() { # repo, layer size in MiB
  local repo="$1" mib="$2" ref="$UPSTREAM/$1:bench"
  local args=()
  for i in 1 2 3; do
    mkdir -p "$tmp/$repo/$i"
    head -c "$((mib * 1024 * 1024 / 3))" /dev/urandom > "$tmp/$repo/$i/data"
    tar -C "$tmp/$repo/$i" -cf "$tmp/$repo/$i.tar" data
    args+=(-f "$tmp/$repo/$i.tar")
  done
  crane append --insecure --platform linux/amd64 "${args[@]}" -t "$ref" >/dev/null
  echo "pushed $ref"
}

push_image bench/small 2
push_image bench/medium 8
push_image bench/large 32
python3 ../../images/describe.py --registry "$UPSTREAM" --insecure images.txt > images.json
echo "wrote test/local/images.json"
```

- [ ] **Step 6: Bring the stack up and seed**

Run:
```bash
chmod +x test/local/seed.sh
UPSTREAM_URL=http://upstream:5000 TLS_VERIFY=false zot/render-config.sh > test/local/zot-config.json
docker compose -f test/local/compose.yaml up -d
sleep 3
test/local/seed.sh
jq '.images | length' test/local/images.json
```
Expected: three `pushed …` lines, then `3`.

- [ ] **Step 7: Verify on-demand sync works end-to-end**

Run:
```bash
d=$(jq -r '.images[0].digest' test/local/images.json)
crane manifest --insecure "localhost:5000/bench/small@$d" | jq -e '.layers | length == 3'
```
Expected: `true` (zot fetched it on demand from upstream).

- [ ] **Step 8: Commit**

```bash
git add zot/render-config.sh test/local/
git commit -m "test: add zot config renderer and local compose harness"
```

---

### Task 3: k6 pull scenario

**Files:**
- Create: `k6/lib/select.js`, `k6/lib/select.test.mjs`, `k6/pull.js`

**Interfaces:**
- Consumes: `images.json` contract.
- Produces (k6 env): `REGISTRY` (e.g. `http://10.0.0.5:5000`), `IMAGES` (path to images.json, default `images.json`), `CLASS` (`10MB|100MB|1GB|mixed`), `VUS` (int), `DURATION` (e.g. `60s`), `LAYER_PARALLELISM` (default `3`).
- Produces (k6 metrics): `image_pull_duration` (Trend, ms), `image_pulls` (Counter), `image_pull_bytes` (Counter), `image_pull_failed` (Rate). All tagged `size_class`, `image`.
- Produces (JS): `imagesForClass(images, cls)`, `pickImage(pool, cls, iteration, vuId, rand)`, `blobDescriptors(manifest)`, `MIX_WEIGHTS`.

- [ ] **Step 1: Write failing tests `k6/lib/select.test.mjs`**

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { imagesForClass, pickImage, blobDescriptors, MIX_WEIGHTS } from './select.js';

const imgs = [
  { class: '10MB', repo: 'a' }, { class: '10MB', repo: 'b' },
  { class: '100MB', repo: 'c' }, { class: '1GB', repo: 'd' },
];

test('imagesForClass filters by class', () => {
  assert.deepEqual(imagesForClass(imgs, '10MB').map(i => i.repo), ['a', 'b']);
});

test('imagesForClass mixed returns all', () => {
  assert.equal(imagesForClass(imgs, 'mixed').length, 4);
});

test('imagesForClass throws on empty class', () => {
  assert.throws(() => imagesForClass(imgs, '5MB'), /no images for class/);
});

test('pickImage round-robins with VU offset', () => {
  const pool = imagesForClass(imgs, '10MB');
  assert.equal(pickImage(pool, '10MB', 0, 1, Math.random).repo, 'b');
  assert.equal(pickImage(pool, '10MB', 1, 1, Math.random).repo, 'a');
});

test('pickImage mixed follows weights', () => {
  assert.deepEqual(MIX_WEIGHTS, { '10MB': 70, '100MB': 25, '1GB': 5 });
  const pool = imagesForClass(imgs, 'mixed');
  assert.equal(pickImage(pool, 'mixed', 0, 1, () => 0.0).class, '10MB');
  assert.equal(pickImage(pool, 'mixed', 0, 1, () => 0.69).class, '10MB');
  assert.equal(pickImage(pool, 'mixed', 0, 1, () => 0.70).class, '100MB');
  assert.equal(pickImage(pool, 'mixed', 0, 1, () => 0.96).class, '1GB');
});

test('blobDescriptors returns config then layers', () => {
  const m = { config: { digest: 'c' }, layers: [{ digest: 'l1' }, { digest: 'l2' }] };
  assert.deepEqual(blobDescriptors(m).map(d => d.digest), ['c', 'l1', 'l2']);
});

test('blobDescriptors rejects an index', () => {
  assert.throws(() => blobDescriptors({ manifests: [] }), /index/);
});
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `node --test k6/lib/`
Expected: FAIL — cannot find module `./select.js`

- [ ] **Step 3: Implement `k6/lib/select.js`**

```js
// Pure helpers shared by pull.js and node unit tests. No k6 imports here.
export const MIX_WEIGHTS = { '10MB': 70, '100MB': 25, '1GB': 5 };

export function imagesForClass(images, cls) {
  const pool = cls === 'mixed' ? images : images.filter(i => i.class === cls);
  if (pool.length === 0) throw new Error(`no images for class ${cls}`);
  return pool;
}

export function pickImage(pool, cls, iteration, vuId, rand) {
  if (cls !== 'mixed') return pool[(iteration + vuId) % pool.length];
  let r = rand() * 100;
  let chosen = '1GB';
  for (const [c, w] of Object.entries(MIX_WEIGHTS)) {
    if (r < w) { chosen = c; break; }
    r -= w;
  }
  const inClass = pool.filter(i => i.class === chosen);
  return inClass[Math.floor(rand() * inClass.length)];
}

export function blobDescriptors(manifest) {
  if (manifest.manifests) throw new Error('got an image index; expected an image manifest');
  return [manifest.config, ...manifest.layers];
}
```

Also create `k6/lib/package.json` with `{"type": "module"}` so node treats `select.js` as ESM (k6 ignores it).

- [ ] **Step 4: Run tests, verify they pass**

Run: `node --test k6/lib/`
Expected: `# pass 7`, `# fail 0`

- [ ] **Step 5: Implement `k6/pull.js`**

```js
import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';
import { SharedArray } from 'k6/data';
import { Counter, Rate, Trend } from 'k6/metrics';
import { imagesForClass, pickImage, blobDescriptors } from './lib/select.js';

const REGISTRY = __ENV.REGISTRY || 'http://localhost:5000';
const CLASS = __ENV.CLASS || '10MB';
const VUS = parseInt(__ENV.VUS || '1', 10);
const DURATION = __ENV.DURATION || '60s';
const LAYER_PARALLELISM = parseInt(__ENV.LAYER_PARALLELISM || '3', 10);

const ACCEPT = [
  'application/vnd.oci.image.manifest.v1+json',
  'application/vnd.docker.distribution.manifest.v2+json',
].join(', ');

const pool = new SharedArray('images', () =>
  imagesForClass(JSON.parse(open(__ENV.IMAGES || 'images.json')).images, CLASS));

const pullDuration = new Trend('image_pull_duration', true);
const pulls = new Counter('image_pulls');
const pullBytes = new Counter('image_pull_bytes');
const pullFailed = new Rate('image_pull_failed');

export const options = {
  scenarios: { pull: { executor: 'constant-vus', vus: VUS, duration: DURATION, gracefulStop: '120s' } },
  discardResponseBodies: true,
  batch: LAYER_PARALLELISM,
  batchPerHost: LAYER_PARALLELISM,
  summaryTrendStats: ['avg', 'min', 'med', 'p(95)', 'p(99)', 'max'],
  thresholds: {
    image_pull_failed: [{ threshold: 'rate<0.01', abortOnFail: true, delayAbortEval: '10s' }],
    image_pull_duration: [{ threshold: 'p(99)<30000', abortOnFail: true, delayAbortEval: '10s' }],
  },
};

export default function () {
  const img = pickImage(pool, CLASS, exec.vu.iterationInScenario, exec.vu.idInTest, Math.random);
  const tags = { size_class: img.class, image: img.repo };
  const start = Date.now();

  const mres = http.get(`${REGISTRY}/v2/${img.repo}/manifests/${img.digest}`, {
    headers: { Accept: ACCEPT }, responseType: 'text', tags: { ...tags, kind: 'manifest' },
  });
  if (!check(mres, { 'manifest 200': r => r.status === 200 })) {
    pullFailed.add(true, tags);
    return;
  }

  const blobs = blobDescriptors(JSON.parse(mres.body));
  const responses = http.batch(blobs.map(b => ({
    method: 'GET',
    url: `${REGISTRY}/v2/${img.repo}/blobs/${b.digest}`,
    params: { tags: { ...tags, kind: 'blob' }, timeout: '300s' },
  })));
  const ok = check(responses, {
    'all blobs 200 with expected length': rs => rs.every((r, i) =>
      r.status === 200 && parseInt(r.headers['Content-Length'], 10) === blobs[i].size),
  });
  pullFailed.add(!ok, tags);
  if (!ok) return;

  pullDuration.add(Date.now() - start, tags);
  pulls.add(1, tags);
  pullBytes.add(img.size, tags);
}
```

- [ ] **Step 6: Run k6 against the local harness**

Run (stack from Task 2 is up and seeded):
```bash
docker run --rm --network ccdn-local_default -u "$(id -u)" -v "$PWD:/w" -w /w/k6 \
  -e REGISTRY=http://zot:5000 -e IMAGES=/w/test/local/images.json -e CLASS=10MB -e VUS=2 -e DURATION=10s \
  grafana/k6:2.3.0 run -q --summary-export /w/test/local/k6-smoke.json pull.js
jq -e '.metrics.image_pulls.count > 0 and .metrics.image_pull_failed.value == 0' test/local/k6-smoke.json
```
Expected: `true`

Run the same with `-e CLASS=mixed` → Expected: `true`.

Confirm failures are counted and the abort threshold fires (nothing listens on 5999):
```bash
docker run --rm --network ccdn-local_default -u "$(id -u)" -v "$PWD:/w" -w /w/k6 \
  -e REGISTRY=http://zot:5999 -e IMAGES=/w/test/local/images.json -e CLASS=10MB -e VUS=1 -e DURATION=30s \
  grafana/k6:2.3.0 run -q pull.js; echo "exit=$?"
```
Expected: `exit=99` (thresholds crossed).

- [ ] **Step 7: Commit**

```bash
git add k6/
git commit -m "feat: add k6 image pull scenario"
```

---

### Task 4: Warm-up script

**Files:**
- Create: `scripts/warmup.sh`

**Interfaces:**
- Consumes: `images.json`.
- Produces: `scripts/warmup.sh <zot-registry-host:port> <images.json>` with env `BLOB_CHECK` (a command prefix that runs a shell command on the zot host, e.g. `ssh -F terraform/app/ssh_config zot` or `docker exec ccdn-local-zot-1`) and `ZOT_ROOT` (default `/var/lib/zot`). Exit 0 only if every manifest+blob of every image is on zot's disk.

- [ ] **Step 1: Write `scripts/warmup.sh`**

```bash
#!/usr/bin/env bash
# Pull every image once through zot (triggers on-demand sync) and verify all blobs are on disk.
set -euo pipefail
REG="${1:?zot registry host:port}"; IMAGES="${2:?images.json}"
ZOT_ROOT="${ZOT_ROOT:-/var/lib/zot}"
: "${BLOB_CHECK:?BLOB_CHECK command prefix required, e.g. 'ssh -F terraform/app/ssh_config zot'}"

missing=0
while read -r repo digest; do
  echo "warmup: $repo@$digest"
  crane pull --insecure --format oci "$REG/$repo@$digest" "$(mktemp -d)/img" >/dev/null
  manifest="$(crane manifest --insecure "$REG/$repo@$digest")"
  for d in "$digest" $(jq -r '.config.digest, .layers[].digest' <<<"$manifest"); do
    path="$ZOT_ROOT/$repo/blobs/sha256/${d#sha256:}"
    if ! $BLOB_CHECK test -s "$path"; then
      echo "MISSING on zot disk: $path" >&2; missing=$((missing + 1))
    fi
  done
done < <(jq -r '.images[] | "\(.repo) \(.digest)"' "$IMAGES")

if (( missing > 0 )); then echo "warmup: $missing blobs missing" >&2; exit 1; fi
echo "warmup: all images cached"
```

- [ ] **Step 2: Test locally — happy path**

Run:
```bash
chmod +x scripts/warmup.sh
BLOB_CHECK="docker run --rm -v ccdn-local_zot-data:/var/lib/zot alpine" scripts/warmup.sh localhost:5000 test/local/images.json
```
Expected: ends with `warmup: all images cached`, exit 0. (The zot image has no shell or `test` binary, so the local check mounts zot's volume into alpine.)

- [ ] **Step 3: Test locally — cache really serves without upstream**

Run:
```bash
docker compose -f test/local/compose.yaml stop upstream
docker run --rm --network ccdn-local_default -u "$(id -u)" -v "$PWD:/w" -w /w/k6 \
  -e REGISTRY=http://zot:5000 -e IMAGES=/w/test/local/images.json -e CLASS=mixed -e VUS=2 -e DURATION=10s \
  grafana/k6:2.3.0 run -q --summary-export /w/test/local/k6-smoke.json pull.js
jq -e '.metrics.image_pull_failed.value == 0' test/local/k6-smoke.json
docker compose -f test/local/compose.yaml start upstream
```
Expected: `true` — proves warm pulls by digest never touch upstream.

- [ ] **Step 4: Test locally — the check really detects a missing blob**

Run:
```bash
d=$(jq -r '.images[0].digest' test/local/images.json)
layer=$(crane manifest --insecure localhost:5000/bench/small@$d | jq -r '.layers[0].digest')
docker run --rm -v ccdn-local_zot-data:/var/lib/zot alpine \
  test -s "/var/lib/zot/bench/small/blobs/sha256/${layer#sha256:}" && echo present
docker run --rm -v ccdn-local_zot-data:/var/lib/zot alpine \
  test -s "/var/lib/zot/bench/small/blobs/sha256/deadbeef" || echo "absent detected"
```
Expected: `present`, then `absent detected` — proves the path layout used by warmup.sh matches zot's on-disk layout and a missing file fails the check. (Deleting a real blob from zot's store is avoided: zot would serve a 404 or re-sync, muddying the test.)

- [ ] **Step 5: Commit**

```bash
git add scripts/warmup.sh
git commit -m "feat: add warm-up script with on-disk cache verification"
```

---

### Task 5: Report library, step check, report generator

**Files:**
- Create: `scripts/benchlib.py`, `scripts/test_benchlib.py`, `scripts/stepcheck.py`, `scripts/report.py`

**Interfaces:**
- Consumes: results directory contract; Prometheus HTTP API at `PROM_URL` (default `http://localhost:9090`).
- Produces (Python, `benchlib`):
  - `read_steps(path) -> list[dict]` (steps.csv rows; ints for `vus, repeat, start_epoch, end_epoch, exit_code, drop_caches`)
  - `summarize_k6(summary: dict) -> dict` keys: `pulls_per_s, mb_per_s, p50_ms, p95_ms, p99_ms, max_ms, fail_rate`
  - `prom_avg(query_fn, promql: str, start: int, end: int) -> float | None` — averages a range query (step 5s); `None` if no data
  - `node_stats(query_fn, start, end) -> dict` keys: `zot_cpu_pct, zot_rss_mb, zot_nic_tx_gbps, zot_disk_read_mbps, client_cpu_pct`
  - `verdict(stats: dict, exit_code: int) -> tuple[str, bool]` → (`saturation` in `{"zot-cpu","zot-nic","client","threshold","none"}`, `valid`)
  - `http_query_fn(prom_url) -> callable(promql, start, end) -> list[float]`
  - Constants: `NIC_BASELINE_GBPS = 12.5`, `NIC_SAT = 0.95`, `CPU_SAT_PCT = 90.0`, `CLIENT_CPU_MAX_PCT = 70.0`
- Produces (CLI): `scripts/stepcheck.py <results_dir> <run_id>` → exit 0 = continue ladder, exit 3 = stop ladder (threshold abort or NIC saturated), prints verdict.
- Produces (CLI): `scripts/report.py <results_dir>` → writes `<results_dir>/report.md`.

Prometheus job/instance labels expected (set in Task 6 `prometheus.yml.tpl`): job `zot` (zot `/metrics`), job `node` with label `role="zot"` or `role="client"`.

PromQL used:
- zot CPU %: `100 * (1 - avg(rate(node_cpu_seconds_total{role="zot",mode="idle"}[15s])))`
- client CPU %: same with `role="client"`
- zot RSS MB: `process_resident_memory_bytes{job="zot"} / 1e6`
- zot NIC tx Gbps: `sum(rate(node_network_transmit_bytes_total{role="zot",device!="lo"}[15s])) * 8 / 1e9`
- zot disk read MB/s: `sum(rate(node_disk_read_bytes_total{role="zot"}[15s])) / 1e6`

- [ ] **Step 1: Write failing tests `scripts/test_benchlib.py`**

```python
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
    assert set(stats) == {"zot_cpu_pct", "zot_rss_mb", "zot_nic_tx_gbps", "zot_disk_read_mbps", "client_cpu_pct"}
    assert len(seen) == 5


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
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd scripts && python3 -m pytest -q test_benchlib.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'benchlib'`

- [ ] **Step 3: Implement `scripts/benchlib.py`**

```python
"""Shared helpers: k6 summaries, Prometheus queries, per-step verdicts."""
import csv
import json
import urllib.parse
import urllib.request

NIC_BASELINE_GBPS = 12.5
NIC_SAT = 0.95
CPU_SAT_PCT = 90.0
CLIENT_CPU_MAX_PCT = 70.0

INT_FIELDS = ("vus", "repeat", "start_epoch", "end_epoch", "exit_code", "drop_caches")

QUERIES = {
    "zot_cpu_pct": '100 * (1 - avg(rate(node_cpu_seconds_total{role="zot",mode="idle"}[15s])))',
    "zot_rss_mb": 'process_resident_memory_bytes{job="zot"} / 1e6',
    "zot_nic_tx_gbps": 'sum(rate(node_network_transmit_bytes_total{role="zot",device!="lo"}[15s])) * 8 / 1e9',
    "zot_disk_read_mbps": 'sum(rate(node_disk_read_bytes_total{role="zot"}[15s])) / 1e6',
    "client_cpu_pct": '100 * (1 - avg(rate(node_cpu_seconds_total{role="client",mode="idle"}[15s])))',
}


def read_steps(path):
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        for k in INT_FIELDS:
            r[k] = int(r[k])
    return rows


def summarize_k6(summary):
    m = summary["metrics"]
    pulls = m.get("image_pulls", {})
    nbytes = m.get("image_pull_bytes", {})
    dur = m.get("image_pull_duration", {})
    return {
        "pulls_per_s": pulls.get("rate", 0),
        "mb_per_s": nbytes.get("rate", 0) / 1e6,
        "p50_ms": dur.get("med"),
        "p95_ms": dur.get("p(95)"),
        "p99_ms": dur.get("p(99)"),
        "max_ms": dur.get("max"),
        "fail_rate": m.get("image_pull_failed", {}).get("value", 0),
    }


def prom_avg(query_fn, promql, start, end):
    values = query_fn(promql, start, end)
    return sum(values) / len(values) if values else None


def node_stats(query_fn, start, end):
    return {k: prom_avg(query_fn, q, start, end) for k, q in QUERIES.items()}


def verdict(stats, exit_code):
    client = stats.get("client_cpu_pct")
    valid = client is not None and client <= CLIENT_CPU_MAX_PCT
    if client is not None and client > CLIENT_CPU_MAX_PCT:
        return "client", False
    if exit_code == 99:
        return "threshold", valid
    if (stats.get("zot_nic_tx_gbps") or 0) >= NIC_BASELINE_GBPS * NIC_SAT:
        return "zot-nic", valid
    if (stats.get("zot_cpu_pct") or 0) >= CPU_SAT_PCT:
        return "zot-cpu", valid
    return "none", valid


def http_query_fn(prom_url):
    def query(promql, start, end):
        qs = urllib.parse.urlencode({"query": promql, "start": start, "end": end, "step": 5})
        with urllib.request.urlopen(f"{prom_url}/api/v1/query_range?{qs}", timeout=30) as r:
            data = json.load(r)["data"]["result"]
        return [float(v) for series in data for _, v in series["values"]]
    return query


def load_summary(results_dir, run_id):
    try:
        with open(f"{results_dir}/{run_id}.summary.json") as f:
            return json.load(f)
    except FileNotFoundError:
        return {"metrics": {}}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `cd scripts && python3 -m pytest -q test_benchlib.py`
Expected: `11 passed`

- [ ] **Step 5: Implement `scripts/stepcheck.py`**

```python
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
```

- [ ] **Step 6: Implement `scripts/report.py`**

```python
#!/usr/bin/env python3
"""Generate report.md from a results directory."""
import json
import os
import statistics
import sys
from collections import defaultdict

import benchlib as b


def fmt(v, nd=1):
    return "n/a" if v is None else f"{v:.{nd}f}"


def median_or_none(vals):
    vals = [v for v in vals if v is not None]
    return statistics.median(vals) if vals else None


def spread(vals):
    vals = [v for v in vals if v is not None]
    return (max(vals) - min(vals)) if len(vals) > 1 else None


def build_rows(results_dir, query_fn):
    rows = []
    for s in b.read_steps(f"{results_dir}/steps.csv"):
        k6 = b.summarize_k6(b.load_summary(results_dir, s["run_id"]))
        stats = b.node_stats(query_fn, s["start_epoch"], s["end_epoch"])
        sat, valid = b.verdict(stats, s["exit_code"])
        rows.append({**s, **k6, **stats, "saturation": sat, "valid": valid})
    return rows


def render(rows, env):
    out = ["# zot warm-cache throughput report", ""]
    out.append(f"- zot: {env.get('zot_version', 'n/a')}  config sha256: {env.get('zot_config_sha256', 'n/a')}")
    out.append(f"- instances: zot={env.get('zot_instance_type', 'n/a')} client={env.get('client_instance_type', 'n/a')}")
    out.append(f"- kernel: {env.get('kernel', 'n/a')}  k6: {env.get('k6_version', 'n/a')}")
    out.append("")
    groups = defaultdict(list)
    for r in rows:
        groups[(r["class"], r["drop_caches"], r["vus"])].append(r)
    for (cls, dc) in sorted({(c, d) for c, d, _ in groups}):
        title = f"{cls}" + (" (disk-warm, caches dropped)" if dc else " (page-cache warm)")
        out += [f"## {title}", "",
                "| VUs | pulls/s (median) | spread | MB/s | p50 ms | p99 ms | max ms | fail % | zot CPU % | zot RSS MB | zot NIC Gbps | zot disk MB/s | client CPU % | saturation | valid |",
                "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|"]
        xs, ys = [], []
        for vus in sorted(v for c, d, v in groups if c == cls and d == dc):
            g = groups[(cls, dc, vus)]
            med = lambda k: median_or_none([r[k] for r in g])
            sats = sorted({r["saturation"] for r in g})
            valid = all(r["valid"] for r in g)
            pps = med("pulls_per_s")
            out.append(f"| {vus} | {fmt(pps, 2)} | {fmt(spread([r['pulls_per_s'] for r in g]), 2)} | {fmt(med('mb_per_s'))} "
                       f"| {fmt(med('p50_ms'), 0)} | {fmt(med('p99_ms'), 0)} | {fmt(med('max_ms'), 0)} "
                       f"| {fmt((med('fail_rate') or 0) * 100, 2)} | {fmt(med('zot_cpu_pct'))} | {fmt(med('zot_rss_mb'), 0)} "
                       f"| {fmt(med('zot_nic_tx_gbps'), 2)} | {fmt(med('zot_disk_read_mbps'))} | {fmt(med('client_cpu_pct'))} "
                       f"| {','.join(sats)} | {'yes' if valid else 'NO'} |")
            xs.append(str(vus)); ys.append(round(med("mb_per_s") or 0, 1))
        out += ["", "```mermaid", "xychart-beta", f'  title "{title}: MB/s vs VUs"',
                f"  x-axis [{', '.join(xs)}]", '  y-axis "MB/s"', f"  line [{', '.join(map(str, ys))}]", "```", ""]
    return "\n".join(out) + "\n"


def main():
    results_dir = sys.argv[1]
    env_path = f"{results_dir}/env.json"
    env = json.load(open(env_path)) if os.path.exists(env_path) else {}
    rows = build_rows(results_dir, b.http_query_fn(os.environ.get("PROM_URL", "http://localhost:9090")))
    with open(f"{results_dir}/report.md", "w") as f:
        f.write(render(rows, env))
    with open(f"{results_dir}/rows.json", "w") as f:
        json.dump(rows, f, indent=2)
    print(f"wrote {results_dir}/report.md")


if __name__ == "__main__":
    main()
```

- [ ] **Step 7: Add a render test to `scripts/test_benchlib.py`**

```python
def test_report_render_groups_and_flags():
    import report
    rows = [
        {"run_id": f"10MB-v4-r{i}", "class": "10MB", "vus": 4, "repeat": i, "drop_caches": 0,
         "pulls_per_s": 10.0 + i, "mb_per_s": 100.0, "p50_ms": 5, "p95_ms": 9, "p99_ms": 12, "max_ms": 30,
         "fail_rate": 0.0, "zot_cpu_pct": 20.0, "zot_rss_mb": 80.0, "zot_nic_tx_gbps": 0.8,
         "zot_disk_read_mbps": 0.0, "client_cpu_pct": 75.0 if i == 3 else 10.0,
         "saturation": "client" if i == 3 else "none", "valid": i != 3}
        for i in (1, 2, 3)
    ]
    md = report.render(rows, {"zot_version": "v2.1.21"})
    assert "## 10MB (page-cache warm)" in md
    assert "| 4 | 12.00 | 2.00 |" in md       # median of 11,12,13; spread 2
    assert "client,none" in md and "| NO |" in md
    assert "xychart-beta" in md
```

Run: `cd scripts && python3 -m pytest -q`
Expected: `12 passed`

- [ ] **Step 8: Commit**

```bash
git add scripts/benchlib.py scripts/test_benchlib.py scripts/stepcheck.py scripts/report.py
git commit -m "feat: add step verdicts and markdown report generator"
```

---

### Task 6: Suite runner + env collection, validated locally

**Files:**
- Create: `scripts/run-suite.sh`, `scripts/collect-env.sh`, `test/local/e2e.sh`

**Interfaces:**
- Consumes: `k6/`, `images.json`, `scripts/stepcheck.py`, `scripts/report.py`.
- Produces: `scripts/run-suite.sh` env contract:
  - `RESULTS` (dir, default `results/$(date -u +%Y%m%dT%H%M%SZ)`)
  - `IMAGES` (local path to images.json)
  - `REGISTRY` (URL as seen from the k6 host, e.g. `http://10.0.1.10:5000`)
  - `K6_RUN` (command prefix to run k6 on the load host; `$K6_RUN <k6 args…>` runs k6 with cwd = remote k6 dir. EC2: `ssh -F terraform/app/ssh_config client cd ccdn/k6 &&`; local: a docker run wrapper)
  - `PUSH_FILES` (command to copy `k6/` + images.json to load host; may be `true`)
  - `FETCH_RESULTS` (command to copy `/tmp/ccdn-results/*` from load host into `$RESULTS`; may be `true` when paths are shared)
  - `DROP_CACHES_CMD` (command to drop caches on zot host)
  - `CLASSES` (default `"10MB 100MB 1GB"`), `LADDER` (default `"1 4 16 64 128 256"`), `REPEATS` (default `3`), `DURATION` (default `60s`), `GAP` (default `10`), `MIXED_VUS` (default empty = skip), `DISKWARM_CLASS` (default `1GB`; empty = skip)
  - k6 writes to `/tmp/ccdn-results/<run_id>.{summary.json,html,log}` on the load host.
- Produces: `scripts/collect-env.sh` → prints env.json; env: `ZOT_EXEC`, `CLIENT_EXEC` (command prefixes), `IMAGES`.

- [ ] **Step 1: Write `scripts/run-suite.sh`**

```bash
#!/usr/bin/env bash
# Run the warm-throughput suite: classes × concurrency ladder × repeats (+ mixed, + disk-warm).
set -uo pipefail
cd "$(dirname "$0")/.."
: "${IMAGES:?}" "${REGISTRY:?}" "${K6_RUN:?}" "${PUSH_FILES:?}" "${FETCH_RESULTS:?}" "${DROP_CACHES_CMD:?}"
RESULTS="${RESULTS:-results/$(date -u +%Y%m%dT%H%M%SZ)}"
CLASSES="${CLASSES-10MB 100MB 1GB}"
LADDER="${LADDER:-1 4 16 64 128 256}"
REPEATS="${REPEATS:-3}"
DURATION="${DURATION:-60s}"
GAP="${GAP:-10}"
MIXED_VUS="${MIXED_VUS:-}"
DISKWARM_CLASS="${DISKWARM_CLASS-1GB}"
export RESULTS

mkdir -p "$RESULTS"
cp "$IMAGES" "$RESULTS/images.json"
echo "run_id,class,vus,repeat,start_epoch,end_epoch,exit_code,drop_caches" > "$RESULTS/steps.csv"
eval "$PUSH_FILES" || { echo "PUSH_FILES failed" >&2; exit 1; }

run_step() { # class vus repeat drop_caches -> returns stepcheck exit code
  local cls="$1" vus="$2" rep="$3" dc="$4"
  local run_id="${cls}-v${vus}-r${rep}$([[ $dc == 1 ]] && echo -dc)"
  [[ $dc == 1 ]] && { eval "$DROP_CACHES_CMD" || echo "WARN: drop caches failed" >&2; }
  echo "=== $run_id"
  local start end rc
  start=$(date +%s)
  local cmd="env K6_WEB_DASHBOARD_EXPORT=/tmp/ccdn-results/$run_id.html K6_WEB_DASHBOARD_PORT=-1"
  cmd+=" k6 run -q --out web-dashboard --out experimental-prometheus-rw"
  cmd+=" --summary-export /tmp/ccdn-results/$run_id.summary.json"
  cmd+=" -e REGISTRY=$REGISTRY -e IMAGES=../images.json -e CLASS=$cls -e VUS=$vus -e DURATION=$DURATION"
  cmd+=" --tag run_id=$run_id pull.js > /tmp/ccdn-results/$run_id.log 2>&1"
  # eval strips the %q layer, so $cmd reaches K6_RUN as ONE argument:
  # `ssh host 'cd dir &&' "$cmd"` (ssh joins args into one remote shell line) and `sh -c "$cmd"` both work.
  eval "$K6_RUN $(printf '%q' "$cmd")"
  rc=$?
  end=$(date +%s)
  echo "$run_id,$cls,$vus,$rep,$start,$end,$rc,$dc" >> "$RESULTS/steps.csv"
  sleep "$GAP"
  python3 scripts/stepcheck.py "$RESULTS" "$run_id"
}

for rep in $(seq 1 "$REPEATS"); do
  for cls in $CLASSES; do
    for vus in $LADDER; do
      run_step "$cls" "$vus" "$rep" 0; rc=$?
      if [[ $rc == 3 ]]; then echo "--- $cls r$rep: ladder stopped at $vus VUs"; break; fi
    done
  done
  [[ -n $MIXED_VUS ]] && run_step mixed "$MIXED_VUS" "$rep" 0
done

if [[ -n $DISKWARM_CLASS ]]; then
  for vus in $LADDER; do
    run_step "$DISKWARM_CLASS" "$vus" 1 1; rc=$?
    [[ $rc == 3 ]] && break
  done
fi

eval "$FETCH_RESULTS"
python3 scripts/report.py "$RESULTS"
echo "results in $RESULTS"
```

Note: `K6_PROMETHEUS_RW_SERVER_URL` and `K6_PROMETHEUS_RW_TREND_STATS` come from the load host's environment (Task 7 writes them into `/etc/environment` on the client; the local wrapper passes them with `-e`).

- [ ] **Step 2: Write `scripts/collect-env.sh`**

```bash
#!/usr/bin/env bash
# Print env.json describing the benchmark environment.
set -euo pipefail
: "${ZOT_EXEC:?}" "${CLIENT_EXEC:?}" "${IMAGES:?}"
# ZOT_EXEC / CLIENT_EXEC are ssh prefixes: a single string argument is run by the remote shell.
imds='TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60"); curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type'
jq -n \
  --arg zot_version "$($ZOT_EXEC /usr/local/bin/zot --version 2>&1 | head -1 || echo n/a)" \
  --arg zot_config_sha256 "$($ZOT_EXEC sudo sha256sum /etc/zot/config.json | cut -d' ' -f1)" \
  --arg zot_instance_type "$($ZOT_EXEC "$imds" 2>/dev/null || echo n/a)" \
  --arg client_instance_type "$($CLIENT_EXEC "$imds" 2>/dev/null || echo n/a)" \
  --arg kernel "$($ZOT_EXEC uname -r)" \
  --arg k6_version "$($CLIENT_EXEC k6 version | head -1)" \
  --argjson images "$(cat "$IMAGES")" \
  '$ARGS.named'
```

- [ ] **Step 3: Write `test/local/e2e.sh` (short local run of the whole suite)**

```bash
#!/usr/bin/env bash
# Local end-to-end: stack up, seed, warm up, run a tiny suite, generate report.
set -euo pipefail
cd "$(dirname "$0")/../.."
UPSTREAM_URL=http://upstream:5000 TLS_VERIFY=false zot/render-config.sh > test/local/zot-config.json
docker compose -f test/local/compose.yaml up -d
sleep 3
test/local/seed.sh
BLOB_CHECK="docker run --rm -v ccdn-local_zot-data:/var/lib/zot alpine" \
  scripts/warmup.sh localhost:5000 test/local/images.json

mkdir -p test/local/results/k6out
export RESULTS=test/local/results/run
rm -rf "$RESULTS"
export IMAGES=test/local/images.json
export REGISTRY=http://zot:5000
# Load host = a k6 container; /tmp/ccdn-results inside it maps to test/local/results/k6out.
export K6_RUN="docker run --rm --network ccdn-local_default -u $(id -u) \
  -v $PWD/k6:/w/k6 -v $PWD/test/local/images.json:/w/images.json -v $PWD/test/local/results/k6out:/tmp/ccdn-results \
  -e K6_PROMETHEUS_RW_SERVER_URL=http://prometheus:9090/api/v1/write \
  -e 'K6_PROMETHEUS_RW_TREND_STATS=p(50),p(95),p(99),max' \
  -w /w/k6 --entrypoint sh grafana/k6:2.3.0 -c"
export PUSH_FILES=true
export FETCH_RESULTS="cp test/local/results/k6out/* \"\$RESULTS\"/"
export DROP_CACHES_CMD=true
export CLASSES="10MB 1GB" LADDER="1 2" REPEATS=1 DURATION=25s GAP=2 MIXED_VUS=2 DISKWARM_CLASS=1GB
scripts/run-suite.sh
```

- [ ] **Step 4: Run local e2e**

Run: `chmod +x scripts/*.sh test/local/*.sh && test/local/e2e.sh`
Expected:
- `=== 10MB-v1-r1`, `=== 10MB-v2-r1`, `=== 1GB-v1-r1`, `=== 1GB-v2-r1`, `=== mixed-v2-r1`, `=== 1GB-v1-r1-dc`, `=== 1GB-v2-r1-dc`
- each followed by a `stepcheck …` line (locally `valid=False` because there is no node_exporter / `role="client"` — expected)
- `wrote test/local/results/run/report.md`

Check:
```bash
wc -l < test/local/results/run/steps.csv            # 8 (header + 7)
ls test/local/results/run/*.summary.json | wc -l    # 7
ls test/local/results/run/*.html | wc -l            # 7 (runs are 25s, long enough for export)
grep -c '^## ' test/local/results/run/report.md     # 4 (10MB, 1GB, mixed, 1GB disk-warm)
curl -s 'localhost:9090/api/v1/label/__name__/values' | jq -r '.data[]' | grep -c '^k6_image_pull'  # ≥ 1: remote write works
```

- [ ] **Step 5: Tear down local stack**

Run: `docker compose -f test/local/compose.yaml down -v`

- [ ] **Step 6: Commit**

```bash
git add scripts/run-suite.sh scripts/collect-env.sh test/local/e2e.sh
git commit -m "feat: add suite runner and env collection, validated with local e2e"
```

---

### Task 7: Terraform infrastructure + node provisioning

**Files:**
- Create: `infra/versions.tf`, `infra/variables.tf`, `infra/main.tf`, `infra/outputs.tf`, `infra/userdata-zot.sh.tpl`, `infra/userdata-client.sh.tpl`, `monitoring/prometheus.yml.tpl`, `zot/zot.service`

**Interfaces:**
- Consumes: `zot/render-config.sh` (embedded into zot user-data via `templatefile`), `zot/zot.service`, `monitoring/prometheus.yml.tpl`.
- Produces (outputs): `zot_private_ip`, `zot_public_ip`, `client_public_ip`, `ecr_registry` (`<acct>.dkr.ecr.us-east-1.amazonaws.com`); files `infra/.ssh/id_ed25519`, `terraform/app/ssh_config` with hosts `zot` and `client` (user `ec2-user`).
- Produces (on client): `/etc/environment` contains `K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write` and `K6_PROMETHEUS_RW_TREND_STATS=p(50),p(95),p(99),max`; `~ec2-user/ccdn/` exists; `/tmp/ccdn-results/` exists; `k6`, `crane`, `jq`, `python3` installed.
- Produces (on zot): zot on `:5000`, node_exporter on `:9100`, `/var/lib/zot` on NVMe XFS, `/usr/local/bin/zot`, `/etc/zot/config.json`.

- [ ] **Step 1: Write `zot/zot.service`**

```ini
[Unit]
Description=zot registry
After=network-online.target var-lib-zot.mount
Wants=network-online.target
Requires=var-lib-zot.mount

[Service]
Type=simple
Environment=GOMEMLIMIT=24GiB
Environment=AWS_REGION=us-east-1
ExecStart=/usr/local/bin/zot serve /etc/zot/config.json
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Write `monitoring/prometheus.yml.tpl`**

```yaml
global:
  scrape_interval: 5s
scrape_configs:
  - job_name: zot
    static_configs:
      - targets: ["${zot_ip}:5000"]
  - job_name: node
    static_configs:
      - targets: ["${zot_ip}:9100"]
        labels: { role: zot }
      - targets: ["localhost:9100"]
        labels: { role: client }
```

- [ ] **Step 3: Write `infra/versions.tf` and `infra/variables.tf`**

```hcl
# versions.tf
terraform {
  required_version = ">= 1.14"
  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 6.0" }
    tls   = { source = "hashicorp/tls", version = "~> 4.0" }
    local = { source = "hashicorp/local", version = "~> 2.5" }
    http  = { source = "hashicorp/http", version = "~> 3.4" }
  }
}

provider "aws" {
  region  = var.region
  default_tags { tags = { Project = "ccdn-bench" } }
}
```

```hcl
# variables.tf
variable "region"      { default = "us-east-1" }
variable "az"          { default = "us-east-1a" }
variable "instance_type" { default = "m6idn.2xlarge" }
variable "zot_version"   { default = "v2.1.21" }
variable "k6_version"    { default = "v2.3.0" }
variable "prometheus_version"    { default = "3.15.0" }
variable "node_exporter_version" { default = "1.12.1" }
variable "crane_version"         { default = "v0.22.1" }
variable "operator_cidr" {
  description = "CIDR allowed to SSH. Empty = auto-detect current public IP /32."
  default     = ""
}
```

- [ ] **Step 4: Write `infra/main.tf`**

```hcl
data "aws_caller_identity" "me" {}
data "http" "myip" { url = "https://checkip.amazonaws.com" }

locals {
  operator_cidr = var.operator_cidr != "" ? var.operator_cidr : "${chomp(data.http.myip.response_body)}/32"
  ecr_registry  = "${data.aws_caller_identity.me.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

data "aws_vpc" "default" { default = true }

data "aws_subnet" "az" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = var.az
  default_for_az    = true
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "tls_private_key" "ssh" { algorithm = "ED25519" }

resource "local_sensitive_file" "ssh_key" {
  content         = tls_private_key.ssh.private_key_openssh
  filename        = "${path.module}/.ssh/id_ed25519"
  file_permission = "0600"
}

resource "aws_key_pair" "bench" {
  key_name   = "ccdn-bench"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "aws_placement_group" "bench" {
  name     = "ccdn-bench"
  strategy = "cluster"
}

resource "aws_security_group" "bench" {
  name   = "ccdn-bench"
  vpc_id = data.aws_vpc.default.id

  ingress {
    description = "ssh from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.operator_cidr]
  }
  ingress {
    description = "all traffic between bench nodes"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "zot" {
  name = "ccdn-bench-zot"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "zot_ecr" {
  role       = aws_iam_role.zot.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "zot" {
  name = "ccdn-bench-zot"
  role = aws_iam_role.zot.name
}

resource "aws_instance" "zot" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.az.id
  placement_group        = aws_placement_group.bench.id
  key_name               = aws_key_pair.bench.key_name
  vpc_security_group_ids = [aws_security_group.bench.id]
  iam_instance_profile   = aws_iam_instance_profile.zot.name
  root_block_device {
    volume_type = "gp3"
    volume_size = 30
  }
  user_data = templatefile("${path.module}/userdata-zot.sh.tpl", {
    zot_version           = var.zot_version
    node_exporter_version = var.node_exporter_version
    ecr_registry          = local.ecr_registry
    render_config         = file("${path.module}/../zot/render-config.sh")
    zot_service           = file("${path.module}/../zot/zot.service")
  })
  user_data_replace_on_change = true
  tags = { Name = "ccdn-zot" }
}

resource "aws_instance" "client" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.az.id
  placement_group        = aws_placement_group.bench.id
  key_name               = aws_key_pair.bench.key_name
  vpc_security_group_ids = [aws_security_group.bench.id]
  root_block_device {
    volume_type = "gp3"
    volume_size = 30
  }
  user_data = templatefile("${path.module}/userdata-client.sh.tpl", {
    k6_version            = var.k6_version
    prometheus_version    = var.prometheus_version
    node_exporter_version = var.node_exporter_version
    crane_version         = var.crane_version
    prometheus_yml        = templatefile("${path.module}/../monitoring/prometheus.yml.tpl", { zot_ip = aws_instance.zot.private_ip })
  })
  user_data_replace_on_change = true
  tags = { Name = "ccdn-client" }
}

resource "local_file" "ssh_config" {
  filename = "${path.module}/ssh_config"
  content  = <<-EOT
    Host zot
      HostName ${aws_instance.zot.public_ip}
    Host client
      HostName ${aws_instance.client.public_ip}
    Host *
      User ec2-user
      IdentityFile ${abspath(local_sensitive_file.ssh_key.filename)}
      StrictHostKeyChecking accept-new
      UserKnownHostsFile ${abspath(path.module)}/.ssh/known_hosts
  EOT
}
```

- [ ] **Step 5: Write `infra/outputs.tf`**

```hcl
output "zot_private_ip"   { value = aws_instance.zot.private_ip }
output "zot_public_ip"    { value = aws_instance.zot.public_ip }
output "client_public_ip" { value = aws_instance.client.public_ip }
output "ecr_registry"     { value = local.ecr_registry }
```

- [ ] **Step 6: Write `infra/userdata-zot.sh.tpl`**

Common sysctl block is duplicated in both user-data files on purpose (each file must be self-contained for cloud-init).

```bash
#!/bin/bash
set -euxo pipefail

# --- network tuning (identical on both nodes)
cat > /etc/sysctl.d/90-bench.conf <<'EOF'
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 2097152
EOF
sysctl --system

dnf install -y jq xfsprogs

# --- instance-store NVMe -> /var/lib/zot (XFS)
dev=/dev/$(lsblk -dno NAME,MODEL | awk '/Instance Storage/ {print $1; exit}')
test -b "$dev"
mkfs.xfs -f "$dev"
mkdir -p /var/lib/zot
echo "$dev /var/lib/zot xfs defaults,noatime,nofail 0 2" >> /etc/fstab
systemctl daemon-reload
mount /var/lib/zot

# --- zot
curl -fsSL -o /usr/local/bin/zot \
  "https://github.com/project-zot/zot/releases/download/${zot_version}/zot-linux-amd64"
chmod +x /usr/local/bin/zot
mkdir -p /etc/zot
cat > /usr/local/bin/zot-render-config <<'EOF'
${render_config}
EOF
chmod +x /usr/local/bin/zot-render-config
UPSTREAM_URL="https://${ecr_registry}" CREDENTIAL_HELPER=ecr /usr/local/bin/zot-render-config > /etc/zot/config.json
cat > /etc/systemd/system/zot.service <<'EOF'
${zot_service}
EOF

# --- node_exporter
curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${node_exporter_version}/node_exporter-${node_exporter_version}.linux-amd64.tar.gz" \
  | tar -xz -C /usr/local/bin --strip-components=1 "node_exporter-${node_exporter_version}.linux-amd64/node_exporter"
cat > /etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=node_exporter
[Service]
ExecStart=/usr/local/bin/node_exporter
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node_exporter zot
touch /var/local/bootstrap-done
```

Note: `templatefile` interpolates `${…}`. Shell variables here (`$dev`, `$1`) have no braces, so it is not interpolated. Do not introduce `${shell_var}` in these templates; if needed, escape as `$${shell_var}`.

- [ ] **Step 7: Write `infra/userdata-client.sh.tpl`**

```bash
#!/bin/bash
set -euxo pipefail

cat > /etc/sysctl.d/90-bench.conf <<'EOF'
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 2097152
EOF
sysctl --system
cat > /etc/security/limits.d/90-bench.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
EOF

dnf install -y jq python3 tar gzip rsync

# --- k6
dnf install -y "https://github.com/grafana/k6/releases/download/${k6_version}/k6-${k6_version}-linux-amd64.rpm"

# --- crane
curl -fsSL "https://github.com/google/go-containerregistry/releases/download/${crane_version}/go-containerregistry_Linux_x86_64.tar.gz" \
  | tar -xz -C /usr/local/bin crane

# --- node_exporter
curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${node_exporter_version}/node_exporter-${node_exporter_version}.linux-amd64.tar.gz" \
  | tar -xz -C /usr/local/bin --strip-components=1 "node_exporter-${node_exporter_version}.linux-amd64/node_exporter"
cat > /etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=node_exporter
[Service]
ExecStart=/usr/local/bin/node_exporter
Restart=always
[Install]
WantedBy=multi-user.target
EOF

# --- prometheus
mkdir -p /opt/prometheus /var/lib/prometheus /etc/prometheus
curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v${prometheus_version}/prometheus-${prometheus_version}.linux-amd64.tar.gz" \
  | tar -xz -C /opt/prometheus --strip-components=1
cat > /etc/prometheus/prometheus.yml <<'EOF'
${prometheus_yml}
EOF
cat > /etc/systemd/system/prometheus.service <<'EOF'
[Unit]
Description=prometheus
[Service]
ExecStart=/opt/prometheus/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus --storage.tsdb.retention.time=30d --web.enable-remote-write-receiver
Restart=always
[Install]
WantedBy=multi-user.target
EOF

cat >> /etc/environment <<'EOF'
K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write
K6_PROMETHEUS_RW_TREND_STATS="p(50),p(95),p(99),max"
EOF

install -d -o ec2-user -g ec2-user /home/ec2-user/ccdn /tmp/ccdn-results
systemctl daemon-reload
systemctl enable --now node_exporter prometheus
touch /var/local/bootstrap-done
```

- [ ] **Step 8: Static validation**

Run:
```bash
cd terraform/app && terraform init -input=false && terraform fmt -check && terraform validate
```
Expected: `Success! The configuration is valid.` (run `terraform fmt` first if `-check` fails, then re-run).

Run: `docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable scripts/*.sh test/local/*.sh zot/*.sh`
Expected: no errors (fix warnings or add targeted `# shellcheck disable=` with reason). `images/preload.sh` is checked in Task 8.

- [ ] **Step 9: Plan (no apply yet)**

Run: `cd terraform/app && terraform plan -out=tfplan`
Expected: `Plan: 11 to add, 0 to change, 0 to destroy.` (key pair, placement group, SG, IAM role, policy attachment, instance profile, 2 instances, tls key, 2 local files). Exact count may differ by ±1; review the resource list, not the number.

- [ ] **Step 10: Commit**

```bash
git add infra/*.tf infra/*.tpl monitoring/ zot/zot.service
git commit -m "feat: add terraform infra and node provisioning for EC2 bench"
```

---

### Task 8: ECR preload script

**Files:**
- Create: `images/preload.sh`

**Interfaces:**
- Consumes: `images/images.txt`, `images/describe.py`, terraform output `ecr_registry`.
- Produces: ECR repos `bench/*` with tag `bench` (linux/amd64 single-platform manifests), and `images/images.json`.

- [ ] **Step 1: Write `images/preload.sh`**

```bash
#!/usr/bin/env bash
# Copy the benchmark images (linux/amd64 only) into ECR under bench/* and write images.json.
set -euo pipefail
cd "$(dirname "$0")"
REGION="${AWS_REGION:-us-east-1}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
ECR="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

aws --region "$REGION" ecr get-login-password \
  | crane auth login "$ECR" -u AWS --password-stdin

grep -vE '^\s*(#|$)' images.txt | while read -r cls src repo; do
  aws --region "$REGION" ecr describe-repositories --repository-names "$repo" >/dev/null 2>&1 \
    || aws --region "$REGION" ecr create-repository --repository-name "$repo" >/dev/null
  digest="$(crane digest --platform linux/amd64 "$src")"
  echo "copy [$cls] $src@$digest -> $ECR/$repo:bench"
  crane copy --platform linux/amd64 "$src@$digest" "$ECR/$repo:bench"
done

python3 describe.py --registry "$ECR" --tag bench images.txt > images.json
jq -r '.images[] | "\(.class)\t\(.repo)\t\(.size / 1e6 | floor) MB\t\(.layers) layers\t\(.digest)"' images.json
```

- [ ] **Step 2: Shellcheck**

Run: `docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable images/preload.sh`
Expected: no output.

- [ ] **Step 3: Run preload (creates ECR repos — cheap, reversible)**

Run: `images/preload.sh`
Expected: 6 `copy …` lines, then a table of 6 rows whose sizes match the spec (~10, 14, 115, 80, 1004, 856 MB) ± upstream drift for `:latest`.

Verify single-platform manifests (not indexes):
```bash
jq -e '[.images[].layers] | all(. > 0)' images/images.json
```
Expected: `true`

- [ ] **Step 4: Commit**

```bash
git add images/preload.sh
git commit -m "feat: add ECR preload script"
```

(`images/images.json` is gitignored; the digests are recorded per run in `results/<ts>/images.json` and `env.json`.)

---

### Task 9: EC2 run (requires operator go-ahead — spends money)

**Files:**
- Create: `README.md`
- Results: `results/<ts>/` (gitignored); commit only `report.md` copy to `docs/results/2026-09-27-zot-warm-throughput.md` if the user asks.

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Ask the user for go-ahead** (≈ $1.3/h for 2× m6idn.2xlarge; expected wall time ≈ 3–4h for 3 repeats). Do not `terraform apply` without an explicit yes.

- [ ] **Step 2: Apply and wait for bootstrap**

Run:
```bash
cd terraform/app && terraform apply tfplan && cd ..
for h in zot client; do
  until ssh -F terraform/app/ssh_config $h test -f /var/local/bootstrap-done; do sleep 10; done; echo "$h ready"
done
ssh -F terraform/app/ssh_config zot 'systemctl is-active zot node_exporter; findmnt /var/lib/zot; /usr/local/bin/zot --version'
ssh -F terraform/app/ssh_config client 'systemctl is-active prometheus node_exporter; k6 version'
```
Expected: all `active`; `/var/lib/zot` on `/dev/nvme1n1` (or similar) `xfs`; zot `v2.1.21`; k6 `v2.3.0`.

Check Prometheus targets are up:
```bash
ssh -F terraform/app/ssh_config client 'curl -s localhost:9090/api/v1/targets | jq -r ".data.activeTargets[] | \"\(.labels.job) \(.labels.role // \"-\") \(.health)\""'
```
Expected: `zot - up`, `node zot up`, `node client up`.

- [ ] **Step 3: Baseline network check** (proves the 12.5 Gbps path, independent of zot)

```bash
ssh -F terraform/app/ssh_config zot 'sudo dnf install -y iperf3 >/dev/null && (iperf3 -s -D)'
ssh -F terraform/app/ssh_config client "sudo dnf install -y iperf3 >/dev/null && iperf3 -c $(terraform -chdir=terraform/app output -raw zot_private_ip) -R -P 8 -t 30 | tail -3"
```
Expected: receiver ≈ 12 Gbps (initially may burst higher, up to 40 Gbps; record both the first and last 10s). Record in `results/<ts>/notes.md`.

- [ ] **Step 4: Warm up**

Run:
```bash
ZOT_IP=$(terraform -chdir=terraform/app output -raw zot_private_ip)
ssh -F terraform/app/ssh_config -fN -L 25000:$ZOT_IP:5000 client   # tunnel so crane on operator can reach zot
BLOB_CHECK="ssh -F terraform/app/ssh_config zot sudo" scripts/warmup.sh localhost:25000 images/images.json
```
Expected: `warmup: all images cached`.

- [ ] **Step 5: Smoke run (short, 1 repeat, 2 steps) to validate wiring on EC2**

```bash
ssh -F terraform/app/ssh_config -fN -L 29090:localhost:9090 client
export PROM_URL=http://localhost:29090   # local 9090 is taken by another project
export IMAGES=images/images.json
export REGISTRY=http://$ZOT_IP:5000
export K6_RUN="ssh -F terraform/app/ssh_config client 'set -a; . /etc/environment; set +a; cd ccdn/k6 &&' "
export PUSH_FILES="ssh -F terraform/app/ssh_config client 'rm -f /tmp/ccdn-results/*' && rsync -a -e 'ssh -F terraform/app/ssh_config' k6 images/images.json client:ccdn/"
export FETCH_RESULTS="rsync -a -e 'ssh -F terraform/app/ssh_config' client:/tmp/ccdn-results/ \"\$RESULTS\"/"
export DROP_CACHES_CMD="ssh -F terraform/app/ssh_config zot 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null'"
export ZOT_EXEC="ssh -F terraform/app/ssh_config zot" CLIENT_EXEC="ssh -F terraform/app/ssh_config client"
RESULTS=results/smoke CLASSES=10MB LADDER="1 4" REPEATS=1 DURATION=30s DISKWARM_CLASS= scripts/run-suite.sh
```
Expected: 2 steps, `report.md` with a `10MB (page-cache warm)` table where `client CPU %`, `zot CPU %`, `zot NIC Gbps` are numbers (not `n/a`) and `valid` = `yes`.

Note: `images.json` lands at `ccdn/images.json` on the client and k6 runs from `ccdn/k6` with `IMAGES=../images.json` — matches run-suite.

- [ ] **Step 6: Full run**

```bash
TS=$(date -u +%Y%m%dT%H%M%SZ)
RESULTS=results/$TS scripts/run-suite.sh 2>&1 | tee results/$TS.console.log
IMAGES=images/images.json scripts/collect-env.sh > results/$TS/env.json
python3 scripts/report.py results/$TS
```
Then pick `MIXED_VUS` = the highest VUs step where 100MB was still `saturation=none`, and run mixed only:
```bash
RESULTS=results/$TS-mixed CLASSES= MIXED_VUS=<n> DISKWARM_CLASS= scripts/run-suite.sh
```
(With `CLASSES=` empty the class loops are skipped; mixed runs `REPEATS` times.)

- [ ] **Step 7: Sanity-check results**

- Every step `valid=yes`; if any `client` saturation → stop, report to user, propose adding a 2nd client (do not silently continue).
- k6 `data_received` rate ≈ `image_pull_bytes` rate (±5%) for a few steps (`jq '.metrics.data_received.rate, .metrics.image_pull_bytes.rate' results/$TS/*-v16-r1.summary.json`).
- zot log has no sync activity during timed runs: `ssh -F terraform/app/ssh_config zot "sudo journalctl -u zot --since '<run start>' | grep -ci sync"` → expect `0` (or only startup lines).

- [ ] **Step 8: Destroy**

```bash
cd terraform/app && terraform destroy -auto-approve
```
Expected: `Destroy complete!`. Leave ECR repos (≈ $0.20/month) unless the user asks to delete them.

- [ ] **Step 9: Write `README.md` and commit**

`README.md` contents: purpose (1 paragraph), prerequisites (terraform, crane, jq, python3, docker, AWS profile), local e2e (`test/local/e2e.sh`), EC2 flow (Steps 2–8 above as commands), result layout, link to spec.

```bash
git add README.md
git commit -m "docs: add benchmark runbook"
```

Report the headline numbers to the user from `results/$TS/report.md` and ask whether to commit the report under `docs/results/`.

---

## Deviations during execution (2026-09-27)

- **zot `http.compat: ["docker2s2"]`** added to `render-config.sh`: zot v2.1.21 refuses `preserveDigest` without it ("can not use PreserveDigest option without enabling http.Compat").
- **Local harness host ports** changed to zot `15000`, upstream `15001`, Prometheus `19090` (5000/9090 were taken by other local containers). `e2e.sh` sets `PROM_URL=http://localhost:19090`. For Task 9 Step 4, use tunnel port `25000` instead of `15000`.
- **Tests run with** `uvx pytest` (pytest not installed) and `node --test k6/lib/*.test.mjs` (node 25 rejects a directory argument).
- **`preload.sh`** uses a temporary `DOCKER_CONFIG` so ECR credentials never touch `~/.docker/config.json`.
- **Warm-up local check** always uses the alpine volume mount (zot image has no shell / `test`); missing-blob detection verified by path check rather than deleting a blob.
- **Preloaded ECR digests equal the Docker Hub linux/amd64 digests** (crane copy preserves manifests).
- **EC2 Prometheus tunnel** uses local port `29090` with `PROM_URL=http://localhost:29090` (local 9090 is taken).
- **Terraform split into two stacks.** `terraform/infra` (long-lived: 6 ECR repos derived from `images/images.txt`, zot IAM role + instance profile) and `terraform/app` (per-run: EC2 nodes, SG, placement group, key pair, ssh_config), which reads `ecr_registry` and `zot_instance_profile` from infra's local state via `terraform_remote_state`. Order: apply infra → `images/preload.sh` → apply app; destroy only app after a run. `preload.sh` no longer creates repos. The 6 repos created earlier by `preload.sh` were imported into `terraform/infra`.
- **zot storage moved to a dedicated gp3 EBS volume** (`/dev/sdf`, size/IOPS/throughput variables, mounted by UUID) so the cache persists across stop/start; instance type split into `zot_instance_type` / `client_instance_type`. Not applied during the first EC2 session (would replace the running zot node).
