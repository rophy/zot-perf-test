import http from 'k6/http';
import { check } from 'k6';
import { blobDescriptors, parseBearerChallenge, tokenURL } from './select.js';

const ACCEPT = [
  'application/vnd.oci.image.manifest.v1+json',
  'application/vnd.docker.distribution.manifest.v2+json',
].join(', ');

// Pull one image by digest as docker/containerd do: manifest, then config + layers in one
// http.batch (parallelism = options.batchPerHost). Registries with token auth (e.g. Harbor)
// answer 401 even for anonymous pulls: fetch a pull token once, then retry.
// Returns { ok, status } where status is the failing response's status (0 = timeout).
export function pullImage(registry, img, tags, timeouts = { manifest: '60s', blob: '300s' }) {
  const manifestURL = `${registry}/v2/${img.repo}/manifests/${img.digest}`;
  const headers = { Accept: ACCEPT };
  const mparams = () => ({ headers, responseType: 'text', tags: { ...tags, kind: 'manifest' }, timeout: timeouts.manifest });
  let mres = http.get(manifestURL, mparams());
  if (mres.status === 401) {
    const challenge = parseBearerChallenge(mres.headers['Www-Authenticate']);
    if (!challenge) return { ok: false, status: 401 };
    const tres = http.get(tokenURL(challenge, img.repo), { responseType: 'text', tags: { ...tags, kind: 'token' } });
    if (tres.status !== 200) return { ok: false, status: tres.status };
    const body = JSON.parse(tres.body);
    headers.Authorization = `Bearer ${body.token || body.access_token}`;
    mres = http.get(manifestURL, mparams());
  }
  if (!check(mres, { 'manifest 200': r => r.status === 200 })) return { ok: false, status: mres.status };

  const blobs = blobDescriptors(JSON.parse(mres.body));
  const responses = http.batch(blobs.map(b => ({
    method: 'GET',
    url: `${registry}/v2/${img.repo}/blobs/${b.digest}`,
    params: { headers: headers.Authorization ? { Authorization: headers.Authorization } : {},
              tags: { ...tags, kind: 'blob' }, timeout: timeouts.blob },
  })));
  const bad = responses.find((r, i) =>
    r.status !== 200 || parseInt(r.headers['Content-Length'], 10) !== blobs[i].size);
  check(responses, { 'all blobs 200 with expected length': () => !bad });
  return bad ? { ok: false, status: bad.status } : { ok: true, status: 200 };
}
