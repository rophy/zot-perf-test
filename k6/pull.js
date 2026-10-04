import exec from 'k6/execution';
import { SharedArray } from 'k6/data';
import { Counter, Rate, Trend } from 'k6/metrics';
import { imagesForClass, pickImage } from './lib/select.js';
import { pullImage } from './lib/pullimage.js';

const REGISTRY = __ENV.REGISTRY || 'http://localhost:5000';
const CLASS = __ENV.CLASS || '10MB';
const VUS = parseInt(__ENV.VUS || '1', 10);
const DURATION = __ENV.DURATION || '60s';
const LAYER_PARALLELISM = parseInt(__ENV.LAYER_PARALLELISM || '3', 10);

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
  const { ok } = pullImage(REGISTRY, img, tags);
  pullFailed.add(!ok, tags);
  if (!ok) return;
  pullDuration.add(Date.now() - start, tags);
  pulls.add(1, tags);
  pullBytes.add(img.size, tags);
}
