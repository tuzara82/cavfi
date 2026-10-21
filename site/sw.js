// CavFi service worker: makes the site installable and opens instantly.
// The page and addresses.json are always fetched fresh when online (network first);
// icons and the ethers library come from the cache. Chain data is never cached.
const CACHE = 'cavfi-v2';
const SHELL = ['/', '/index.html', '/addresses.json', '/favicon.svg', '/apple-touch-icon.png', '/icon-192.png', '/icon-512.png', '/manifest.webmanifest',
  'https://cdnjs.cloudflare.com/ajax/libs/ethers/5.7.2/ethers.umd.min.js'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => Promise.all(SHELL.map(u => c.add(new Request(u, {cache: 'reload'})).catch(() => {})))).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;                      // RPC calls are POST: never touched
  const url = new URL(req.url);
  const same = url.origin === self.location.origin;
  const fresh = same && (req.mode === 'navigate' || url.pathname === '/' || url.pathname.endsWith('.html') || url.pathname.endsWith('addresses.json'));
  if (fresh){
    e.respondWith(fetch(req).then(r => { if (r.ok){ const copy = r.clone(); caches.open(CACHE).then(c => c.put(req.mode === 'navigate' ? '/' : req, copy)); } return r; })
      .catch(() => caches.match(req.mode === 'navigate' ? '/' : req).then(r => r || caches.match('/index.html'))));
    return;
  }
  const cacheable = same || url.hostname === 'cdnjs.cloudflare.com' || url.hostname.endsWith('fonts.gstatic.com') || url.hostname === 'fonts.googleapis.com';
  if (!cacheable) return;
  e.respondWith(caches.match(req).then(hit => hit || fetch(req).then(r => {
    if (r.ok || r.type === 'opaque'){ const copy = r.clone(); caches.open(CACHE).then(c => c.put(req, copy)); }
    return r;
  })));
});
