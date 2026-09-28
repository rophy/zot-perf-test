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
