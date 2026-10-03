import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';
import { SharedArray } from 'k6/data';
import { Counter, Rate, Trend } from 'k6/metrics';
import { imagesForClass, pickImage, blobDescriptors, parseBearerChallenge, tokenURL } from './lib/select.js';

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
  insecureSkipTLSVerify: true,
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

  const manifestURL = `${REGISTRY}/v2/${img.repo}/manifests/${img.digest}`;
  const headers = { Accept: ACCEPT };
  let mres = http.get(manifestURL, { headers, responseType: 'text', tags: { ...tags, kind: 'manifest' } });
  // Registries with token auth (e.g. Harbor) answer 401 even for anonymous pulls: fetch a
  // pull token once per image pull, as docker/containerd do, then retry.
  if (mres.status === 401) {
    const challenge = parseBearerChallenge(mres.headers['Www-Authenticate']);
    const tres = challenge && http.get(tokenURL(challenge, img.repo),
      { responseType: 'text', tags: { ...tags, kind: 'token' } });
    if (!tres || tres.status !== 200) {
      pullFailed.add(true, tags);
      return;
    }
    const body = JSON.parse(tres.body);
    headers.Authorization = `Bearer ${body.token || body.access_token}`;
    mres = http.get(manifestURL, { headers, responseType: 'text', tags: { ...tags, kind: 'manifest' } });
  }
  if (!check(mres, { 'manifest 200': r => r.status === 200 })) {
    pullFailed.add(true, tags);
    return;
  }

  const blobs = blobDescriptors(JSON.parse(mres.body));
  const responses = http.batch(blobs.map(b => ({
    method: 'GET',
    url: `${REGISTRY}/v2/${img.repo}/blobs/${b.digest}`,
    params: { headers: headers.Authorization ? { Authorization: headers.Authorization } : {},
              tags: { ...tags, kind: 'blob' }, timeout: '300s' },
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
