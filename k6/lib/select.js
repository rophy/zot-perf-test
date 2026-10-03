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
