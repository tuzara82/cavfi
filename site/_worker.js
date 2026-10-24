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

export default {
  async fetch(request, env, ctx){
    const url = new URL(request.url);
    if (url.pathname === '/api/quest'){
      if (request.method === 'OPTIONS') return new Response(null, {headers: {'access-control-allow-origin': '*', 'access-control-allow-methods': 'GET, POST', 'access-control-allow-headers': 'content-type, x-api-key'}});
      return quest(request, env, url);
    }
    return env.ASSETS.fetch(request);
  },
};
