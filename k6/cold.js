import exec from 'k6/execution';
import { SharedArray } from 'k6/data';
import { Counter, Rate, Trend } from 'k6/metrics';
import { imagesForClass, coldPick, errorCategory } from './lib/select.js';
import { pullImage } from './lib/pullimage.js';

const REGISTRY = __ENV.REGISTRY || 'http://localhost:5000';
const SCENARIO = __ENV.SCENARIO || 'unique';          // unique | stampede
const CLASS = __ENV.CLASS || 'c10m';
const VUS = parseInt(__ENV.VUS || '1', 10);
const IMAGE_INDEX = parseInt(__ENV.IMAGE_INDEX || '0', 10);
const POOL_LIMIT = parseInt(__ENV.POOL_LIMIT || '0', 10);  // >0: only the first N images (smoke runs)
const TIMEOUT = __ENV.TIMEOUT || '600s';
const LAYER_PARALLELISM = parseInt(__ENV.LAYER_PARALLELISM || '3', 10);

const pool = new SharedArray('images', () => {
  const all = imagesForClass(JSON.parse(open(__ENV.IMAGES || 'images.json')).images, CLASS);
  return POOL_LIMIT > 0 ? all.slice(0, POOL_LIMIT) : all;
});

const pullDuration = new Trend('image_pull_duration', true);
const pulls = new Counter('image_pulls');
const pullBytes = new Counter('image_pull_bytes');
const pullFailed = new Rate('image_pull_failed');
const pullErrors = {
  timeout: new Counter('pull_err_timeout'), '4xx': new Counter('pull_err_4xx'),
  '5xx': new Counter('pull_err_5xx'), other: new Counter('pull_err_other'),
};

export const options = {
  scenarios: {
    cold: SCENARIO === 'unique'
      ? { executor: 'shared-iterations', vus: VUS, iterations: pool.length, maxDuration: '30m' }
      : { executor: 'per-vu-iterations', vus: VUS, iterations: 1, maxDuration: '30m' },
  },
  discardResponseBodies: true,
  batch: LAYER_PARALLELISM,
  batchPerHost: LAYER_PARALLELISM,
  summaryTrendStats: ['avg', 'min', 'med', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const img = coldPick(pool, SCENARIO, exec.scenario.iterationInTest, IMAGE_INDEX);
  const tags = { size_class: img.class };
  const start = Date.now();
  const r = pullImage(REGISTRY, img, tags, { manifest: TIMEOUT, blob: TIMEOUT });
  pullFailed.add(!r.ok, tags);
  if (!r.ok) {
    pullErrors[errorCategory(r.status)].add(1, tags);
    return;
  }
  pullDuration.add(Date.now() - start, tags);
  pulls.add(1, tags);
  pullBytes.add(img.size, tags);
}
