// CavFi Cloudflare Pages worker (advanced mode).
// Serves the static site unchanged, plus one small API used by quest platforms:
//
//   GET  /api/quest?task=swap&address=0x...      -> {"ok":1,"task":"swap","message":"..."}  (Galxe REST credential)
//   POST /api/quest?task=swap   (Zealy API task)  -> 200 {"message":"..."} when done, 400 {"message":"..."} when not
//
// Optional query: since=2026-10-25 counts only transactions from that UTC day on (for a campaign).
// Optional Cloudflare variable ZEALY_API_KEY: if set, POST requests must send it as X-Api-Key.
// Everything is read from the DogeOS testnet: contract calls go to the RPC, transaction history to Blockscout.

const RPC = 'https://rpc.testnet.dogeos.com';
let rpcUrl = RPC;
const EXPLORER = 'https://blockscout.testnet.dogeos.com';

// tasks checked from the wallet's own transactions: contract key(s) in addresses.json + function selectors
const TX_TASKS = {
  swap:   {keys: ['router'], sel: ['0x7ff36ab5', '0x18cbafe5', '0x38ed1739'], need: 'Make a swap on cavfi.com (Swap page).'},
  liq:    {keys: ['router'], sel: ['0xe8e33700', '0xf305d719'], need: 'Add liquidity to any pool on cavfi.com (Liquidity page).'},
  gm:     {keys: ['gm'], sel: ['0xc0129d43'], need: 'Say gm on the cavfi.com home page.'},
  arena:  {keys: ['arena'], sel: ['0x7b0472f0'], need: 'Back a token in the Arena: cavfi.com/arena.html'},
  launch: {keys: ['launch'], sel: ['0xcce7ec13', '0x6a272462', '0x2fde70d1'], need: 'Buy, sell or launch a token on the cavfi.com Launchpad.'},
  limit:  {keys: ['limit'], sel: ['0x391560b2', '0xb0987adb'], need: 'Place a limit order on cavfi.com (Swap page, Limit tab).'},
  dca:    {keys: ['dca'], sel: ['0x7b070932', '0xd5c55b52'], need: 'Start an auto-buy on cavfi.com (Swap page, Auto-buy tab).'},
  farm:   {keys: ['farm', 'stake'], sel: ['0xe2bbb158', '0x608fc37a', '0xddc63262'], need: 'Stake or harvest on cavfi.com Farms.'},
  predict:{keys: ['predict', 'predictV2', 'predictV1'], sel: ['0x8decaec0'], need: 'Back YES or NO on a DOGE price market: cavfi.com/#predict'},
  duel:   {keys: ['duel'], sel: ['0xc139da6f', '0x19b05f49'], need: 'Start or accept an Arena duel: cavfi.com/#duels'},
  guess:  {keys: ['guess', 'guessV2', 'guessV1'], sel: ['0x1e997a6d'], need: 'Make your free daily guess of the DOGE price: cavfi.com/#guess'},
  callout:{keys: ['callouts'], sel: ['0xf55332ab'], need: 'Call a Launchpad token: open it on cavfi.com/#launch and press Call it.'},
};
// tasks checked from contract state
const STATE_TASKS = {
  name:     {need: 'Claim a .cav name on cavfi.com (Names page).'},
  nft:      {need: 'Mint a CavFi Cavalier on cavfi.com (NFTs page).'},
  quest:    {need: 'Finish at least one daily quest on cavfi.com. Days are recorded after midnight UTC.'},
  pup:      {need: 'Say gm 7 days in a row on cavfi.com to earn the Early Pup badge.'},
  champion: {need: 'Claim the Arena Champion badge after backing a winning token in the Arena.'},
};

let addrCache = null, addrAt = 0;
async function addresses(env, url){
  if (addrCache && Date.now() - addrAt < 300000) return addrCache;
  const r = await env.ASSETS.fetch(new Request(new URL('/addresses.json', url)));
  addrCache = await r.json(); addrAt = Date.now();
  return addrCache;
}
async function call(to, data){
  const r = await fetch(rpcUrl, {method: 'POST', headers: {'content-type': 'application/json'},
    body: JSON.stringify({jsonrpc: '2.0', id: 1, method: 'eth_call', params: [{to, data}, 'latest']})});
  const j = await r.json();
  if (j.error) throw new Error('rpc: ' + j.error.message);
  return j.result || '0x';
}
const word = (hex, i) => BigInt('0x' + (hex.slice(2 + 64 * i, 66 + 64 * i) || '0'));
const pad = a => a.toLowerCase().replace(/^0x/, '').padStart(64, '0');

async function stateDone(task, A, who){
  if (task === 'name') return A.names && word(await call(A.names, '0x70a08231' + pad(who)), 0) > 0n;
  if (task === 'nft') return A.nft && word(await call(A.nft, '0x70a08231' + pad(who)), 0) > 0n;
  if (task === 'pup') return A.gm && word(await call(A.gm, '0x00fdd58e' + pad(who) + pad('1')), 0) > 0n;
  if (task === 'champion') return A.champion && word(await call(A.champion, '0x00fdd58e' + pad(who) + pad('1')), 0) > 0n;
  if (task === 'quest') return A.quests && word(await call(A.quests, '0x0aae7a6b' + pad(who)), 3) > 0n; // info(): quests done in total
  return false;
}
async function txDone(t, A, who, since, explorer){
  const targets = t.keys.map(k => (A[k] || '').toLowerCase()).filter(Boolean);
  if (!targets.length) return false;
  let url = `${explorer}/api/v2/addresses/${who}/transactions?filter=from`;
  for (let page = 0; page < 8; page++){
    const r = await fetch(url, {headers: {accept: 'application/json'}});
    if (!r.ok) throw new Error('explorer ' + r.status);
    const j = await r.json();
    for (const tx of j.items || []){
      const ts = Math.floor(Date.parse(tx.timestamp) / 1000);
      if (since && ts < since) return false;
      const to = (tx.to && tx.to.hash || '').toLowerCase(), sel = (tx.raw_input || '').slice(0, 10).toLowerCase();
      const ok = tx.status === 'ok' || tx.result === 'success';
      if (ok && targets.includes(to) && t.sel.includes(sel)) return true;
    }
    if (!j.next_page_params) break;
    url = `${explorer}/api/v2/addresses/${who}/transactions?filter=from&` + new URLSearchParams(j.next_page_params);
  }
  return false;
}

function json(obj, status){
  return new Response(JSON.stringify(obj), {status: status || 200, headers: {'content-type': 'application/json', 'access-control-allow-origin': '*', 'cache-control': 'no-store'}});
}

async function quest(request, env, url){
  rpcUrl = env.RPC || RPC;
  const isPost = request.method === 'POST';
  const fail = msg => isPost ? json({message: msg}, 400) : json({ok: 0, task, message: msg});
  const task = (url.searchParams.get('task') || '').toLowerCase();
  let who = url.searchParams.get('address') || '';
  if (isPost){
    if (env.ZEALY_API_KEY && request.headers.get('x-api-key') !== env.ZEALY_API_KEY) return json({message: 'Invalid API key.'}, 400);
    try{ const b = await request.json(); who = (b.accounts && b.accounts.wallet) || b.address || who; }catch(e){}
  } else if (request.method !== 'GET') return json({message: 'Use GET or POST.'}, 400);
  if (!TX_TASKS[task] && !STATE_TASKS[task]) return fail(`Unknown task. Use one of: ${[...Object.keys(TX_TASKS), ...Object.keys(STATE_TASKS)].join(', ')}.`);
  if (!/^0x[0-9a-fA-F]{40}$/.test(who)) return fail('Connect an EVM wallet (0x address) to your account first.');
  const sinceStr = url.searchParams.get('since');
  const since = sinceStr && /^\d{4}-\d{2}-\d{2}$/.test(sinceStr) ? Math.floor(Date.parse(sinceStr + 'T00:00:00Z') / 1000) : 0;
  try{
    const A = await addresses(env, url);
    const done = TX_TASKS[task] ? await txDone(TX_TASKS[task], A, who, since, env.EXPLORER || EXPLORER) : await stateDone(task, A, who);
    const need = (TX_TASKS[task] || STATE_TASKS[task]).need;
    if (done) return isPost ? json({message: 'Done! Thanks for testing CavFi 👑'}) : json({ok: 1, task, message: 'done'});
    return fail(`Not found yet for ${who.slice(0, 6)}…${who.slice(-4)} on DogeOS testnet. ${need} If you just did it, wait a minute and try again.`);
  }catch(e){
    return fail('Could not check right now (DogeOS testnet RPC or explorer is slow). Please try again in a minute.');
  }
}

// Share pages: cavfi.com/u/borislav.cav, cavfi.com/duel/5 and cavfi.com/p/3 serve the site with their own
// link-preview title and text, so a shared link shows what it is on X and Telegram. The page itself then
// opens the right view (/#u/…, /#duel/5, /#p/3).
async function sharePage(env, url, title, desc, path){
  const r = await env.ASSETS.fetch(new Request(new URL('/', url)));
  if (!r.ok) return r;
  const e = v => String(v).replace(/[&<>"]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'}[c]));
  let html = await r.text();
  const set = (re, val) => { html = html.replace(re, m => m.replace(/content="[^"]*"/, `content="${e(val)}"`)); };
  set(/<meta property="og:title"[^>]*>/, title); set(/<meta name="twitter:title"[^>]*>/, title);
  set(/<meta property="og:description"[^>]*>/, desc); set(/<meta name="twitter:description"[^>]*>/, desc);
  set(/<meta property="og:url"[^>]*>/, 'https://cavfi.com' + path);
  html = html.replace('<title>CavFi</title>', `<title>${e(title)}</title>`);
  return new Response(html, {headers: {'content-type': 'text/html; charset=utf-8', 'cache-control': 'public, max-age=120'}});
}
async function profilePage(env, url, id){
  const clean = id.toLowerCase().replace(/[^a-z0-9.-]/g, '').slice(0, 64);
  const who = /^0x[0-9a-f]{40}$/.test(clean) ? clean.slice(0, 6) + '…' + clean.slice(-4) : clean;
  return sharePage(env, url, `${who} on CavFi`, `Living Cavaliers, badges, leaderboard rank, gm and quest streaks and Arena wins of ${who} on CavFi, the DeFi hub on the DogeOS testnet.`, `/u/${clean}`);
}
const strAt = (hex, off) => { const n = Number(word('0x' + hex.slice(2 + off * 2), 0)); const b = hex.slice(2 + off * 2 + 64, 2 + off * 2 + 64 + n * 2); return decodeURIComponent(b.replace(/../g, '%$&')); };
const fmtK = wei => { const v = Number(wei / 10n ** 14n) / 1e4; return v >= 1000 ? Math.round(v).toLocaleString('en-US') : v.toLocaleString('en-US', {maximumFractionDigits: 2}); };
async function nameOrShort(A, a){
  try{ if (A.names){ const r = await call(A.names, '0xf5c57382' + pad(a)); const n = strAt(r, Number(word(r, 0))); if (/^[a-z0-9-]{3,32}$/.test(n)) return n + '.cav'; } }catch(e){}
  return a.slice(0, 6) + '…' + a.slice(-4);
}
async function duelPage(env, url, id){
  const path = `/duel/${id}`, fallback = () => sharePage(env, url, `Arena duel #${id} on CavFi`, 'A one-on-one bet on the CavFi Arena: whose token rises more against DOGE this round? Winner takes both stakes. DogeOS testnet.', path);
  try{
    rpcUrl = env.RPC || RPC;
    const A = await addresses(env, url); if (!A.duel || !A.arena) return fallback();
    const d = await call(A.duel, '0x9507d39a' + pad(BigInt(id).toString(16)));
    const maker = '0x' + d.slice(26, 66), roundId = word(d, 4), mi = Number(word(d, 5)), ti = Number(word(d, 6)), state = Number(word(d, 7)), stake = word(d, 8);
    const winner = '0x' + d.slice(2 + 64 * 3 + 24, 2 + 64 * 4);
    if (maker === '0x' + '0'.repeat(40)) return fallback();
    const rt = await call(A.arena, '0xfa827e2e' + pad(roundId.toString(16)));
    const off = Number(word(rt, 0)) / 32, tok = i => '0x' + rt.slice(2 + 64 * (off + 1 + i) + 24, 2 + 64 * (off + 2 + i));
    const sym = async a => { try{ const r = await call(a, '0x95d89b41'); return strAt(r, Number(word(r, 0))); }catch(e){ return '?'; } };
    const [a, b, mk] = await Promise.all([sym(tok(mi)), sym(tok(ti)), nameOrShort(A, maker)]);
    const st = Number(stake / 10n ** 18n) ? fmtK(stake) : '0';
    let title = `Duel #${id}: ${a} vs ${b} · ${st} KingS`, desc;
    if (state === 1) desc = `${mk} says ${a} beats ${b} in Arena round #${roundId}. Accept with ${st} KingS and back ${b}: whichever rises more against DOGE wins both stakes. DogeOS testnet.`;
    else if (state === 2) desc = `${a} vs ${b} in Arena round #${roundId}, ${st} KingS each. Decided when the round settles.`;
    else if (state === 3) desc = winner === '0x' + '0'.repeat(40) ? `${a} vs ${b} ended level: both stakes returned.` : `${await nameOrShort(A, winner)} won ${fmtK(stake * 2n)} KingS.`;
    else desc = `This duel was cancelled. Start your own on CavFi.`;
    return sharePage(env, url, title, desc, path);
  }catch(e){ return fallback(); }
}
async function marketPage(env, url, id){
  const path = `/p/${id}`, fallback = () => sharePage(env, url, `DOGE price market #${id} on CavFi`, 'Back YES or NO on the real DOGE price with testnet KingS on CavFi.', path);
  try{
    rpcUrl = env.RPC || RPC;
    const A = await addresses(env, url); if (!A.predict) return fallback();
    // v2 (RedStone) continues the ids of v1: older ids live on predictV1
    // newer versions continue the ids of older ones: try each contract, newest first
    let r = null, ver = A.predictV2 ? 3 : A.predictV1 ? 2 : 1;
    for (const [a, v] of [[A.predict, ver], [A.predictV2, 2], [A.predictV1, 1]]){
      if (!a) continue;
      try{ r = await call(a, '0x9507d39a' + pad(BigInt(id).toString(16))); ver = v; break; }catch(e){}
    }
    if (!r) return fallback();
    const v2 = ver >= 2;
    const t = Number(word(r, 0)), w = i => word('0x' + r.slice(2 + t * 2), i);
    const q = strAt(r, t + Number(w(0))).replace(/^(Weekly|Hourly): w/, 'W');
    const state = Number(w(3)), yesWon = w(4) === 1n, price = Number(w(6)) / 1e8, yes = w(7), no = w(8), tot = yes + no;
    const pY = tot ? Number(yes * 100n / tot) : 0;
    let desc;
    if (state === 2) desc = `${yesWon ? 'YES' : 'NO'} won: DOGE was $${price.toPrecision(3)}. ${fmtK(tot)} KingS pot.`;
    else if (state === 3) desc = 'Refunded: everyone got their KingS back.';
    else desc = tot ? `YES ${pY}% · NO ${100 - pY}% · ${fmtK(tot)} KingS pot. Back YES or NO with testnet KingS.` : 'Nobody has picked a side yet. Back YES or NO with testnet KingS.';
    return sharePage(env, url, q || `DOGE market #${id}`, desc + (ver === 3 ? ' Decided by RedStone\'s DOGE/USD price on DogeOS.' : v2 ? ' Decided by RedStone\'s signed DOGE/USD price.' : ' The CavFi bot reported the price from Binance.'), path);
  }catch(e){ return fallback(); }
}

/* RedStone proxy for the site's "Resolve with RedStone" / "Settle" buttons. RedStone's authenticated gateway
   needs an API key that must not reach the browser: it lives in the worker secret REDSTONE_API_KEY.
   Only DOGE prices at full hours of the last 2 days are served (that is all the site ever asks for), and they
   are cached, so RedStone's rate limit (1 request a second) is never reached. */
async function redstoneProxy(request, env, ctx, url){
  const cors = {'access-control-allow-origin': '*', 'content-type': 'application/json'};
  const m = url.pathname.match(/^\/api\/redstone\/v2\/data-packages\/historical-by-data-feeds\/redstone-primary-prod\/(\d{13})$/);
  const ms = m ? Number(m[1]) : 0, nowMs = Date.now();
  if (!m || url.searchParams.get('dataFeedIds') !== 'DOGE' || ms % 3600000 !== 0 || ms > nowMs || ms < nowMs - 2 * 86400000)
    return new Response('{"error":"not allowed"}', {status: 400, headers: cors});
  if (!env.REDSTONE_API_KEY) return new Response('{"error":"no RedStone API key on this site"}', {status: 503, headers: cors});
  const cache = caches.default, key = new Request(`https://cavfi.com/api/redstone/doge/${ms}`);
  const hit = await cache.match(key); if (hit) return hit;
  const up = await fetch(`${env.REDSTONE_GATEWAY_URL || 'https://oracle-gateway.a.redstone.finance'}/v2/data-packages/historical-by-data-feeds/redstone-primary-prod/${ms}?dataFeedIds=DOGE`,
    {headers: {'x-api-key': env.REDSTONE_API_KEY}});
  const body = await up.text();
  if (!up.ok || body[0] !== '{') return new Response(JSON.stringify({error: 'RedStone gateway ' + up.status}), {status: 502, headers: cors});
  const res = new Response(body, {headers: {...cors, 'cache-control': 'public, max-age=86400'}});
  ctx.waitUntil(cache.put(key, res.clone()));
  return res;
}

export default {
  async fetch(request, env, ctx){
    const url = new URL(request.url);
    if (url.pathname.startsWith('/api/redstone/') && request.method === 'GET'){
      try{ return await redstoneProxy(request, env, ctx, url); }catch(e){ return new Response('{"error":"proxy"}', {status: 502, headers: {'access-control-allow-origin': '*'}}); }
    }
    const um = url.pathname.match(/^\/u\/([^/]{3,80})\/?$/);
    if (um && request.method === 'GET'){ let id = um[1]; try{ id = decodeURIComponent(id); }catch(e){} return profilePage(env, url, id); }
    const dm = url.pathname.match(/^\/duel\/(\d{1,9})\/?$/);
    if (dm && request.method === 'GET') return duelPage(env, url, dm[1]);
    const pm = url.pathname.match(/^\/p\/(\d{1,9})\/?$/);
    if (pm && request.method === 'GET') return marketPage(env, url, pm[1]);
    if (url.pathname === '/api/quest'){
      if (request.method === 'OPTIONS') return new Response(null, {headers: {'access-control-allow-origin': '*', 'access-control-allow-methods': 'GET, POST', 'access-control-allow-headers': 'content-type, x-api-key'}});
      return quest(request, env, url);
    }
    const res = await env.ASSETS.fetch(request);
    // _headers is not applied in worker mode: keep the manifest's content type here
    if (url.pathname.endsWith('.webmanifest') && res.ok){
      const h = new Headers(res.headers); h.set('content-type', 'application/manifest+json');
      return new Response(res.body, {status: res.status, headers: h});
    }
    return res;
  },
};
