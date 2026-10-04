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

// Parse a registry `WWW-Authenticate: Bearer realm="..",service="..",scope=".."` header.
export function parseBearerChallenge(header) {
  if (!header || !/^Bearer\s/i.test(header)) return null;
  const out = {};
  for (const m of header.matchAll(/(\w+)="([^"]*)"/g)) out[m[1]] = m[2];
  return out.realm ? out : null;
}

export function tokenURL(challenge, repo) {
  const q = [];
  if (challenge.service) q.push(`service=${encodeURIComponent(challenge.service)}`);
  q.push(`scope=${encodeURIComponent(`repository:${repo}:pull`)}`);
  return `${challenge.realm}?${q.join('&')}`;
}

// Cold-pull selection. unique: every iteration (test-wide) gets the next never-pulled image.
// stampede: every VU pulls the same image.
export function coldPick(pool, scenario, iterationInTest, imageIndex) {
  let i;
  if (scenario === 'unique') i = iterationInTest;
  else if (scenario === 'stampede') i = imageIndex;
  else throw new Error(`unknown scenario ${scenario}`);
  if (i < 0 || i >= pool.length) throw new Error(`image index ${i} out of range (pool ${pool.length})`);
  return pool[i];
}

// k6 reports status 0 for timeouts and connection errors.
export function errorCategory(status) {
  if (status === 0) return 'timeout';
  if (status >= 400 && status < 500) return '4xx';
  if (status >= 500) return '5xx';
  return 'other';
}

// A blob response is OK when it is a 200 without a k6 transfer error and its Content-Length
// matches the descriptor size, or is absent (chunked streaming, e.g. Harbor proxy-cache cold fetch).
export function blobOK(status, contentLength, errorCode, expectedSize) {
  if (status !== 200 || errorCode) return false;
  if (contentLength === undefined || contentLength === null || contentLength === '') return true;
  return parseInt(contentLength, 10) === expectedSize;
}
