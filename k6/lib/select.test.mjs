import { test } from 'node:test';
import assert from 'node:assert/strict';
import { imagesForClass, pickImage, blobDescriptors, MIX_WEIGHTS, parseBearerChallenge, tokenURL, coldPick, errorCategory, blobOK } from './select.js';

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

test('parseBearerChallenge reads realm and service', () => {
  const c = parseBearerChallenge('Bearer realm="http://h/service/token",service="harbor-registry"');
  assert.deepEqual(c, { realm: 'http://h/service/token', service: 'harbor-registry' });
  assert.equal(parseBearerChallenge('Basic realm="x"'), null);
  assert.equal(parseBearerChallenge(undefined), null);
});

test('tokenURL builds a pull scope', () => {
  assert.equal(tokenURL({ realm: 'http://h/t', service: 's' }, 'proxy/bench/a'),
    'http://h/t?service=s&scope=repository%3Aproxy%2Fbench%2Fa%3Apull');
});

test('coldPick unique walks the pool by test-wide iteration', () => {
  const pool = [{ repo: 'a' }, { repo: 'b' }, { repo: 'c' }];
  assert.equal(coldPick(pool, 'unique', 0, 0).repo, 'a');
  assert.equal(coldPick(pool, 'unique', 2, 0).repo, 'c');
  assert.throws(() => coldPick(pool, 'unique', 3, 0), /out of range/);
});

test('coldPick stampede always returns the chosen image', () => {
  const pool = [{ repo: 'a' }, { repo: 'b' }];
  assert.equal(coldPick(pool, 'stampede', 0, 1).repo, 'b');
  assert.equal(coldPick(pool, 'stampede', 7, 1).repo, 'b');
  assert.throws(() => coldPick(pool, 'stampede', 0, 2), /out of range/);
  assert.throws(() => coldPick(pool, 'other', 0, 0), /unknown scenario/);
});

test('errorCategory buckets HTTP statuses', () => {
  assert.equal(errorCategory(0), 'timeout');
  assert.equal(errorCategory(404), '4xx');
  assert.equal(errorCategory(503), '5xx');
  assert.equal(errorCategory(200), 'other');
});

test('blobOK accepts 200 with matching Content-Length', () => {
  assert.equal(blobOK(200, '100', 0, 100), true);
});
test('blobOK accepts 200 chunked (no Content-Length) without error', () => {
  assert.equal(blobOK(200, undefined, 0, 100), true);
});
test('blobOK rejects a mismatched Content-Length', () => {
  assert.equal(blobOK(200, '99', 0, 100), false);
});
test('blobOK rejects chunked response with a transfer error', () => {
  assert.equal(blobOK(200, undefined, 1000, 100), false);
});
test('blobOK rejects non-200', () => {
  assert.equal(blobOK(404, '100', 0, 100), false);
});
