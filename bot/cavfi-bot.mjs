// CavFi bot: one process that
//   1. fills CavFi limit orders as soon as the pools pay the asked price (earns the 0.1% tip),
//   2. moves mispriced pools back to the market price with small trades from its own wallet,
//   3. posts launches, graduations, big swaps, fills and its own actions to Telegram.
//
// Run from C:\kingswap\bot:   npm install   then   node cavfi-bot.mjs
// Settings: environment variables or a .env file next to this script (see .env.example).
// The private key is asked for (hidden) at start unless PRIVATE_KEY is set.
import { ethers } from 'ethers';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
loadDotEnv(path.join(HERE, '.env'));
const env = (k, d) => (process.env[k] ?? '') !== '' ? process.env[k] : d;
const CFG = {
  rpc: env('RPC_URL', 'https://rpc.testnet.dogeos.com'),
  chainId: Number(env('CHAIN_ID', '6281971')),
  explorer: env('EXPLORER', 'https://blockscout.testnet.dogeos.com'),
  addresses: env('ADDRESSES', path.join(HERE, '..', 'site', 'addresses.json')),
  interval: Number(env('INTERVAL_SEC', '30')) * 1000,
  fillLimits: env('FILL_LIMITS', '1') === '1',
  returnExpired: env('RETURN_EXPIRED', '0') === '1',
  rebalance: env('REBALANCE', '1') === '1',
  minDev: Number(env('REBALANCE_MIN_PCT', '3')) / 100,
  maxUsd: Number(env('REBALANCE_MAX_USD', '50')),
  gasReserve: env('GAS_RESERVE_DOGE', '1'),
  tgToken: env('TELEGRAM_BOT_TOKEN', ''),
  tgChat: env('TELEGRAM_CHAT_ID', ''),
  tgApi: env('TELEGRAM_API', 'https://api.telegram.org'),
  notifySwapUsd: Number(env('NOTIFY_SWAP_USD', '25')),
  arena: env('ARENA', '1') === '1',
  arenaPokeSec: Number(env('ARENA_POKE_SEC', '150')),
  arenaNoise: env('ARENA_NOISE', '1') === '1',
  arenaNoiseTrades: Number(env('ARENA_NOISE_TRADES', '3')),
  arenaNoiseMaxDoge: Number(env('ARENA_NOISE_MAX_DOGE', '1')),
  arenaNoiseMinPct: Number(env('ARENA_NOISE_MIN_PCT', '0.2')) / 100,
  arenaNoiseMaxPct: Number(env('ARENA_NOISE_MAX_PCT', '0.6')) / 100,
  arenaNoiseLowDoge: Number(env('ARENA_NOISE_LOW_DOGE', '60')),
  arenaRemindHours: env('ARENA_REMIND_HOURS', '2,24').split(',').map(Number).filter(x => x > 0),
  dryRun: env('DRY_RUN', '0') === '1',
  once: process.argv.includes('--once'),
};
const STATE_FILE = path.join(HERE, 'bot-state.json');
const FAUCET = { fusdt:'0xC81800b77D91391Ef03d7868cB81204E753093a9', fusdc:'0xD19d2Ffb1c284668b7AFe72cddae1BAF3Bc03925', usd1:'0x25D5E5375e01Ed39Dc856bDCA5040417fD45eA3F' };

const ABI = {
  factory: ['function allPairsLength() view returns (uint256)', 'function allPairs(uint256) view returns (address)'],
  pair: ['function token0() view returns (address)', 'function token1() view returns (address)', 'function getReserves() view returns (uint112,uint112,uint32)'],
  erc20: ['function symbol() view returns (string)', 'function decimals() view returns (uint8)', 'function balanceOf(address) view returns (uint256)',
          'function allowance(address,address) view returns (uint256)', 'function approve(address,uint256) returns (bool)'],
  router: ['function getAmountsOut(uint256,address[]) view returns (uint256[])',
           'function swapExactTokensForTokens(uint256,uint256,address[],address,uint256) returns (uint256[])',
           'function swapExactETHForTokens(uint256,address[],address,uint256) payable returns (uint256[])',
           'function swapExactTokensForETH(uint256,uint256,address[],address,uint256) returns (uint256[])'],
  limit: ['function count() view returns (uint256)',
          'function range(uint256,uint256) view returns (uint256[] ids, tuple(address maker,uint64 expiry,uint8 status,bool nativeIn,bool nativeOut,address tokenIn,address tokenOut,uint256 amountIn,uint256 minOut,uint256 amountOut)[] items)',
          'function fill(uint256,address[]) returns (uint256)', 'function cancel(uint256)',
          'event Filled(uint256 indexed id, address indexed maker, address indexed filler, uint256 amountOut, uint256 tip)'],
  badges: ['function award(address[] to, uint256 id)', 'function balanceOf(address, uint256) view returns (uint256)'],
  social: ['function referralCount() view returns (uint256)', 'function referrals(uint256,uint256) view returns (address[] users, address[] refs)',
           'function balanceOf(address, uint256) view returns (uint256)', 'function awardHerald(address[] to)'],
  vote: ['function nextApply() view returns (uint256)', 'function totalVotes() view returns (uint256)', 'function applyVotes()',
         'function tallies() view returns (uint256[])'],
  farm: ['function poolInfo(uint256) view returns (address lpToken, uint256 allocPoint, uint256, uint256, uint256)', 'function totalAllocPoint() view returns (uint256)', 'function poolLength() view returns (uint256)'],
  arena: ['function poke()', 'function settle() returns (uint256)', 'function settleable() view returns (bool ready, uint256 id)',
          'function currentRound() view returns (uint256 id, uint64 start, uint64 end, uint64 stakingEndsAt, uint256 secondsLeft, uint256 pot, uint16 feeBps, bool live)',
          'function roundTokens(uint256) view returns (address[] tokens, address[] pairs)',
          'event Settled(uint256 indexed id, uint8 winnerMask, uint256 pot, uint256 fee, bool rolledOver, address settler, uint256 tip)',
          'event Staked(uint256 indexed id, address indexed user, uint256 indexed idx, uint256 amount)',
          'function lastSettled() view returns (uint256)', 'function claimable(uint256 id, address user) view returns (uint256)',
          'function getRound(uint256 id) view returns (tuple(uint64 start, uint64 end, uint16 feeBps, uint8 winnerMask, bool settled, uint256 staked, uint256 rollover, uint256 winnerStake, uint256 payout))'],
  names: ['function namesOf(address[]) view returns (string[])'],
  launch: ['event Launched(address indexed token, address indexed creator, string name, string symbol, uint256 target)',
           'event Graduated(address indexed token, address indexed pair, uint256 doge, uint256 amount, uint256 liquidity)'],
};
const SWAP_TOPIC = ethers.utils.id('Swap(address,uint256,uint256,uint256,uint256,address)');

const lk = a => (a || '').toLowerCase();
const fl = (bn, d) => Number(ethers.utils.formatUnits(bn, d));
const short = a => a.slice(0, 6) + '…' + a.slice(-4);
const now = () => Math.floor(Date.now() / 1000);
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const fmtN = n => n >= 1000 ? n.toLocaleString('en-US', {maximumFractionDigits: 0}) : n >= 1 ? n.toLocaleString('en-US', {maximumFractionDigits: 4}) : n.toPrecision(4);
const usd = n => n == null ? '?' : '$' + (n >= 100 ? Math.round(n).toLocaleString('en-US') : n.toFixed(2));
const esc = s => String(s).replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
const txUrl = h => `${CFG.explorer}/tx/${h}`;

function loadDotEnv(f){
  if (!fs.existsSync(f)) return;
  for (const line of fs.readFileSync(f, 'utf8').split(/\r?\n/)){
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/); if (!m || line.trim().startsWith('#')) continue;
    if (process.env[m[1]] == null) process.env[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
}
function askHidden(q){
  return new Promise(res => {
    const rl = readline.createInterface({input: process.stdin, output: process.stdout, terminal: true});
    rl.stdoutMuted = true;
    rl._writeToOutput = s => { if (!rl.stdoutMuted || s.includes(q)) process.stdout.write(s); };
    rl.question(q, a => { rl.close(); process.stdout.write('\n'); res(a.trim()); });
  });
}

// ------------------------------------------------------------------ telegram
async function tg(html){
  if (!CFG.tgToken || !CFG.tgChat) return;
  try{
    const r = await fetch(`${CFG.tgApi}/bot${CFG.tgToken}/sendMessage`, {method:'POST', headers:{'content-type':'application/json'},
      body: JSON.stringify({chat_id: CFG.tgChat, text: html, parse_mode: 'HTML', disable_web_page_preview: true})});
    if (!r.ok) log('telegram error', r.status, (await r.text()).slice(0, 120));
  }catch(e){ log('telegram unreachable:', e.message); }
}

// ------------------------------------------------------------------ setup
const A = JSON.parse(fs.readFileSync(CFG.addresses, 'utf8'));
const provider = new ethers.providers.StaticJsonRpcProvider(CFG.rpc, CFG.chainId);
let wallet = null, me = null;
const tokens = {};   // lk(address) -> {address, symbol, decimals}
let pools = [];      // {address, a0, a1, t0, t1, r0, r1}
let ref = {};        // lk(address) -> USD
const cooldown = {}; // pool -> timestamp
const state = fs.existsSync(STATE_FILE) ? JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')) : {};
const saveState = () => fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 1));

async function token(addr){
  const k = lk(addr); if (tokens[k]) return tokens[k];
  const c = new ethers.Contract(addr, ABI.erc20, provider);
  let symbol = short(addr), decimals = 18;
  try{ [symbol, decimals] = await Promise.all([c.symbol(), c.decimals()]); }catch(e){}
  if (lk(addr) === lk(A.wdoge)) symbol = 'DOGE';
  if (lk(addr) === lk(A.usdt)) symbol = 'cUSDT';
  if (lk(addr) === lk(A.usdc)) symbol = 'cUSDC';
  return tokens[k] = {address: ethers.utils.getAddress(addr), symbol, decimals};
}
/* Only CavFi's own listed tokens are trusted for price checks and pool fixes; anyone can pair up a
   fake token, so pools with unknown tokens are never used to decide a trade. */
const trustedSet = () => new Set([A.wdoge, A.kings, A.usdt, A.usdc, A.lbtc || '0x29789F5A3e4c3113e7165c33A7E3bc592CF6fE0E', A.weth || '0x1a6094Ac3ca3Fc9F1B4777941a5f4AAc16A72000',
  A.fusdt || FAUCET.fusdt, A.fusdc || FAUCET.fusdc, A.usd1 || FAUCET.usd1].filter(Boolean).map(lk));
const MIN_POOL_USD = Number(env('REBALANCE_MIN_POOL_USD', '1'));
function poolUsd(p){ const x = ref[lk(p.a0)], y = ref[lk(p.a1)]; if (x == null || y == null) return 0; return fl(p.r0, p.t0.decimals) * x + fl(p.r1, p.t1.decimals) * y; }
const stableSet = () => new Set([A.usdt, A.usdc, A.fusdt || FAUCET.fusdt, A.fusdc || FAUCET.fusdc, A.usd1 || FAUCET.usd1].filter(Boolean).map(lk));

async function loadPools(){
  const f = new ethers.Contract(A.factory, ABI.factory, provider);
  const n = (await f.allPairsLength()).toNumber();
  const addrs = await Promise.all([...Array(n).keys()].map(i => f.allPairs(i)));
  pools = await Promise.all(addrs.map(async address => {
    const p = new ethers.Contract(address, ABI.pair, provider);
    const [a0, a1, r] = await Promise.all([p.token0(), p.token1(), p.getReserves()]);
    const [t0, t1] = await Promise.all([token(a0), token(a1)]);
    return {address, a0, a1, t0, t1, r0: r[0], r1: r[1]};
  }));
  ref = consensus(pools, stableSet());
}

/* Same consensus pricing as the website's price guard: every pool says
   log p0 - log p1 = log(n1/n0); stablecoins are $1; pick prices that agree with as many
   pools as possible (least absolute error), tie-break by blaming the shallower pool. */
function consensus(list, stable){
  const ps = list.filter(p => !p.r0.isZero() && !p.r1.isZero());
  const edges = ps.map(p => { const n0 = fl(p.r0, p.t0.decimals), n1 = fl(p.r1, p.t1.decimals); return {p, i: lk(p.a0), j: lk(p.a1), off: Math.log(n1 / n0), n0, n1}; });
  const cand = {}; stable.forEach(k => cand[k] = [0]);
  const addC = (k, v) => { const c = (cand[k] ||= []); if (c.length < 8 && !c.some(x => Math.abs(x - v) < 1e-6)) c.push(v); };
  for (let d = 0; d < 4; d++) for (const e of edges){
    if (!stable.has(e.i) && cand[e.j]) for (const v of [...cand[e.j]]) addC(e.i, v + e.off);
    if (!stable.has(e.j) && cand[e.i]) for (const v of [...cand[e.i]]) addC(e.j, v - e.off);
  }
  const free = Object.keys(cand).filter(k => !stable.has(k)), L = {};
  stable.forEach(k => L[k] = 0);
  const cost = () => { let c1 = 0, c2 = 0; for (const e of edges){ if (L[e.i] == null || L[e.j] == null) continue; const r = Math.abs(L[e.i] - L[e.j] - e.off); c1 += r; c2 += r * Math.sqrt(e.n0 * e.n1 * Math.exp(L[e.i] + L[e.j])); } return [c1, c2]; };
  const combos = free.reduce((n, k) => n * cand[k].length, 1);
  let best = null, bestL = {...L};
  if (combos <= 50000){
    const idx = free.map(() => 0);
    for (let n = 0; n < combos; n++){
      free.forEach((k, t) => L[k] = cand[k][idx[t]]);
      const c = cost();
      if (!best || c[0] < best[0] - 1e-9 || (Math.abs(c[0] - best[0]) <= 1e-9 && c[1] < best[1])){ best = c; bestL = {...L}; }
      for (let t = 0; t < idx.length; t++){ if (++idx[t] < cand[free[t]].length) break; idx[t] = 0; }
    }
  } else free.forEach(k => bestL[k] = cand[k][0]);
  const out = {}; for (const k in bestL) out[k] = Math.exp(bestL[k]);
  return out;
}

/* token1-per-token0 price of pool p as seen through every other route (≤3 hops), mid prices */
function altPrices(p){
  const adj = {}, trusted = trustedSet();
  for (const q of pools){
    if (q === p || q.r0.isZero() || q.r1.isZero()) continue;
    if (!trusted.has(lk(q.a0)) || !trusted.has(lk(q.a1)) || poolUsd(q) < MIN_POOL_USD) continue;
    const n0 = fl(q.r0, q.t0.decimals), n1 = fl(q.r1, q.t1.decimals);
    (adj[lk(q.a0)] ||= []).push({to: lk(q.a1), px: n1 / n0});
    (adj[lk(q.a1)] ||= []).push({to: lk(q.a0), px: n0 / n1});
  }
  const out = [], goal = lk(p.a1);
  const walk = (node, px, seen) => {
    for (const e of adj[node] || []){
      if (seen.includes(e.to)) continue;
      if (e.to === goal){ out.push(px * e.px); continue; }
      if (seen.length < 3) walk(e.to, px * e.px, [...seen, e.to]);
    }
  };
  walk(lk(p.a0), 1, [lk(p.a0)]);
  return out;
}

// routes over existing pools, up to 3 hops
function routes(a, b){
  const adj = {};
  for (const p of pools){ if (p.r0.isZero() || p.r1.isZero()) continue; (adj[lk(p.a0)] ||= []).push(p.a1); (adj[lk(p.a1)] ||= []).push(p.a0); }
  const out = [], B = lk(b);
  const walk = (node, pth) => { if (out.length >= 30) return; for (const nx of adj[lk(node)] || []){ const n = lk(nx); if (pth.some(q => lk(q) === n)) continue; if (n === B){ out.push([...pth, b]); continue; } if (pth.length < 3) walk(nx, [...pth, nx]); } };
  walk(a, [a]);
  return out.sort((x, y) => x.length - y.length);
}
async function bestRoute(a, b, amountIn){
  const r = new ethers.Contract(A.router, ABI.router, provider);
  let best = null;
  for (const p of routes(a, b).slice(0, 8)){
    try{ const am = await r.getAmountsOut(amountIn, p); const o = am[am.length - 1]; if (!best || o.gt(best.out)) best = {out: o, path: p}; }catch(e){}
  }
  return best;
}
async function send(label, fn){
  if (CFG.dryRun){ log('[dry run]', label); return null; }
  const tx = await fn();
  log(label, '→', tx.hash);
  const rc = await tx.wait();
  if (rc.status !== 1) throw new Error('reverted');
  return tx;
}
async function ensureAllowance(tokenAddr, spender, amount){
  const c = new ethers.Contract(tokenAddr, ABI.erc20, wallet);
  if ((await c.allowance(me, spender)).gte(amount)) return;
  await send(`approve ${tokens[lk(tokenAddr)]?.symbol || short(tokenAddr)}`, () => c.approve(spender, ethers.constants.MaxUint256));
}

// ------------------------------------------------------------------ 1. limit orders
async function fillLimits(){
  if (!CFG.fillLimits || !A.limit) return;
  const L = new ethers.Contract(A.limit, ABI.limit, wallet);
  const n = (await L.count()).toNumber();
  let start = Math.min(state.limitFrom || 0, n);
  let firstOpen = null;
  for (let s = start; s < n; s += 100){
    const {ids, items} = await L.range(s, 100);
    for (let i = 0; i < ids.length; i++){
      const id = ids[i].toNumber(), o = items[i];
      if (o.status !== 1) continue;
      if (firstOpen == null) firstOpen = id;
      if (o.expiry.toNumber() < now()){
        if (CFG.returnExpired){
          try{ await send(`return expired order #${id}`, () => L.cancel(id)); }catch(e){ log('return failed', id, e.reason || e.message); }
        }
        continue;
      }
      const swapIn = o.amountIn.sub(o.amountIn.mul(10).div(10000));
      const best = await bestRoute(o.tokenIn, o.tokenOut, swapIn);
      if (!best || best.out.lt(o.minOut)) continue;
      try{
        await L.estimateGas.fill(id, best.path);
        const ti = await token(o.tokenIn), to = await token(o.tokenOut);
        const tx = await send(`fill limit #${id}`, () => L.fill(id, best.path));
        const wk = (state.week ||= {fills: 0, fixes: 0, tips: {}}); wk.fills++; wk.tips[ti.symbol] = (wk.tips[ti.symbol] || 0) + fl(o.amountIn.sub(swapIn), ti.decimals); saveState();
        const msg = `✅ <b>Limit order #${id} filled</b>\n${fmtN(fl(o.amountIn, ti.decimals))} ${esc(ti.symbol)} → ${fmtN(fl(best.out, to.decimals))} ${esc(to.symbol)} for ${short(o.maker)}\nTip earned: ${fmtN(fl(o.amountIn.sub(swapIn), ti.decimals))} ${esc(ti.symbol)}` + (tx ? `\n<a href="${txUrl(tx.hash)}">transaction</a>` : '');
        await tg(msg);
      }catch(e){ log('fill skipped', id, (e.reason || e.message || '').slice(0, 100)); }
    }
  }
  state.limitFrom = firstOpen == null ? n : firstOpen; saveState();
}

// ------------------------------------------------------------------ 2. rebalance
async function rebalance(){
  if (!CFG.rebalance) return;
  const stable = stableSet();
  const f = 0.997;
  const trusted = trustedSet();
  for (const p of pools){
    if (p.r0.isZero() || p.r1.isZero()) continue;
    if (!trusted.has(lk(p.a0)) || !trusted.has(lk(p.a1))) continue;    // never trade unknown tokens
    const n0 = fl(p.r0, p.t0.decimals), n1 = fl(p.r1, p.t1.decimals);
    if ((cooldown[lk(p.address)] || 0) > now()) continue;
    // The market price of token0 in token1 must be confirmed by at least two other routes
    // that agree with each other; otherwise we cannot tell which pool is the wrong one.
    const alt = altPrices(p);
    if (alt.length < 2) continue;
    alt.sort((a, b) => a - b);
    if (alt[alt.length - 1] / alt[0] - 1 > 0.02) continue;
    const target = alt[Math.floor(alt.length / 2)];   // token1 per token0
    const dev = (n1 / n0) / target - 1;                // > 0: token0 is overpriced in this pool
    if (Math.abs(dev) < CFG.minDev) continue;
    const K = n0 * n1;
    let sellT, buyT, amt;
    if (dev > 0){ sellT = p.t0; buyT = p.t1; amt = (Math.sqrt(K / target) - n0) / f; }
    else        { sellT = p.t1; buyT = p.t0; amt = (Math.sqrt(K * target) - n1) / f; }
    const pSell = ref[lk(sellT.address)];
    if (!(amt > 0)) continue;
    if (pSell) amt = Math.min(amt, CFG.maxUsd / pSell);
    else continue;                                     // no USD price: cannot apply the size cap
    const isDoge = lk(sellT.address) === lk(A.wdoge), outDoge = lk(buyT.address) === lk(A.wdoge);
    let bal = isDoge ? (await provider.getBalance(me)).sub(ethers.utils.parseEther(CFG.gasReserve))
                     : await new ethers.Contract(sellT.address, ABI.erc20, provider).balanceOf(me);
    if (bal.lte(0)){ log(`${p.t0.symbol}/${p.t1.symbol} is ${(dev*100).toFixed(1)}% off, but the bot has no ${sellT.symbol} to fix it`); cooldown[lk(p.address)] = now() + 600; continue; }
    let amountIn = ethers.utils.parseUnits(amt.toFixed(Math.min(sellT.decimals, 8)), sellT.decimals);
    if (amountIn.gt(bal)) amountIn = bal;
    if (amountIn.isZero()) continue;
    const r = new ethers.Contract(A.router, ABI.router, wallet), pathArr = [sellT.address, buyT.address];
    const am = await r.getAmountsOut(amountIn, pathArr), out = am[1], minOut = out.mul(99).div(100);
    // value both sides at the confirmed market price; skip if fees eat the gain
    const sellIs0 = lk(sellT.address) === lk(p.a0);
    const outAtMkt = fl(amountIn, sellT.decimals) * (sellIs0 ? target : 1 / target);
    if (fl(out, buyT.decimals) < outAtMkt){ cooldown[lk(p.address)] = now() + 300; continue; }
    const pBuy = ref[lk(buyT.address)], vin = pBuy != null ? outAtMkt * pBuy : null, vout = pBuy != null ? fl(out, buyT.decimals) * pBuy : null;
    const dl = now() + 600;
    try{
      if (!isDoge) await ensureAllowance(sellT.address, A.router, amountIn);
      const tx = await send(`fix ${p.t0.symbol}/${p.t1.symbol} (${(dev*100).toFixed(1)}%): ${fmtN(fl(amountIn, sellT.decimals))} ${sellT.symbol} → ${buyT.symbol}`, () =>
        isDoge ? r.swapExactETHForTokens(minOut, pathArr, me, dl, {value: amountIn})
        : outDoge ? r.swapExactTokensForETH(amountIn, minOut, pathArr, me, dl)
        : r.swapExactTokensForTokens(amountIn, minOut, pathArr, me, dl));
      cooldown[lk(p.address)] = now() + 120;
      { const wk = (state.week ||= {fills: 0, fixes: 0, tips: {}}); wk.fixes++; saveState(); }
      await tg(`⚖️ <b>Pool fixed: ${esc(p.t0.symbol)}/${esc(p.t1.symbol)}</b>\nWas ${(dev*100).toFixed(1)}% off the market. Sold ${fmtN(fl(amountIn, sellT.decimals))} ${esc(sellT.symbol)} for ${fmtN(fl(out, buyT.decimals))} ${esc(buyT.symbol)} (${usd(vin)} → ${usd(vout)})` + (tx ? `\n<a href="${txUrl(tx.hash)}">transaction</a>` : ''));
      await loadPools();
    }catch(e){ log('fix failed', p.t0.symbol + '/' + p.t1.symbol, (e.reason || e.message || '').slice(0, 120)); cooldown[lk(p.address)] = now() + 300; }
  }
}

// ------------------------------------------------------------------ 5. badges
const txFromCache = {};
async function swapTrader(l, pairSet){
  const to = lk('0x' + l.topics[2].slice(26));
  if (pairSet.has(to)) return null;                                  // middle hop of a route
  if (A.limit && to === lk(A.limit)) return null;                    // limit fill: the maker is paid by the contract
  if (to === lk(A.router)){                                          // DOGE out: router unwraps, the sender is the trader
    if (!txFromCache[l.transactionHash]){ const t = await provider.getTransaction(l.transactionHash); txFromCache[l.transactionHash] = t ? lk(t.from) : null; }
    return txFromCache[l.transactionHash];
  }
  return to;
}
async function award(addrs, id, label){
  if (!A.badges || !addrs.length || me === ethers.constants.AddressZero) return [];
  const b = new ethers.Contract(A.badges, ABI.badges, wallet);
  const fresh = [];
  for (const a of [...new Set(addrs)]){ if (a === lk(me)) continue; try{ if ((await b.balanceOf(a, id)).isZero()) fresh.push(ethers.utils.getAddress(a)); }catch(e){} }
  if (!fresh.length) return [];
  try{ await send(`award ${label} to ${fresh.length}`, () => b.award(fresh.slice(0, 25), id)); return fresh.slice(0, 25); }
  catch(e){ log('award failed', (e.reason || e.message || '').slice(0, 100)); return []; }
}
/* Weekly summary for Telegram: volume, fees, launches, TVL and what the bot did. */
async function weeklyReport(from, head, vol){
  try{
    let swaps = 0, usdVol = 0;
    for (let b = from; b <= head; b += 9000){
      const logs = await provider.getLogs({fromBlock: b, toBlock: Math.min(head, b + 8999), topics: [SWAP_TOPIC]});
      for (const l of logs){
        const p = pools.find(q => lk(q.address) === lk(l.address)); if (!p) continue;
        const x = ref[lk(p.a0)], y = ref[lk(p.a1)]; if (x == null || y == null) continue;
        const w = i => ethers.BigNumber.from('0x' + l.data.slice(2 + 64 * i, 66 + 64 * i));
        usdVol += fl(w(0), p.t0.decimals) * x + fl(w(1), p.t1.decimals) * y; swaps++;
      }
    }
    let launches = 0, grads = 0;
    if (A.launch){
      const iface = new ethers.utils.Interface(ABI.launch);
      for (let b = from; b <= head; b += 9000){
        const logs = await provider.getLogs({address: A.launch, fromBlock: b, toBlock: Math.min(head, b + 8999), topics: [[iface.getEventTopic('Launched'), iface.getEventTopic('Graduated')]]});
        for (const l of logs){ if (l.topics[0] === iface.getEventTopic('Launched')) launches++; else grads++; }
      }
    }
    const tvl = pools.reduce((t, p) => t + poolUsd(p), 0);
    const traders = Object.keys(vol).length;
    const wk = state.week || {fills: 0, fixes: 0, tips: {}};
    const tips = Object.entries(wk.tips).map(([k, v]) => `${fmtN(v)} ${esc(k)}`).join(', ') || 'none';
    await tg(`📊 <b>CavFi weekly report</b>\n` +
      `Volume: <b>${usd(usdVol)}</b> in ${swaps} swap${swaps === 1 ? '' : 's'} by ${traders} trader${traders === 1 ? '' : 's'}\n` +
      `Fees: ${usd(usdVol * 0.003)} (${usd(usdVol * 0.0025)} to LPs · ${usd(usdVol * 0.0005)} protocol)\n` +
      `Total value locked: ${usd(tvl)} in ${pools.length} pools\n` +
      `Launchpad: ${launches} new token${launches === 1 ? '' : 's'}, ${grads} graduated\n` +
      `Bot: ${wk.fills} limit order${wk.fills === 1 ? '' : 's'} filled, ${wk.fixes} pool fix${wk.fixes === 1 ? '' : 'es'}, tips: ${tips}\n` +
      `<a href="https://cavfi.com/#stats">Open Stats</a>`);
    state.week = {fills: 0, fixes: 0, tips: {}}; saveState();
  }catch(e){ log('weekly report failed:', (e.message || '').slice(0, 100)); }
}

async function weeklyTopTen(){
  if (state.topTenAt == null){ state.topTenAt = now(); saveState(); return; }   // first week starts now
  if (now() - state.topTenAt < 7 * 86400 && process.env.FORCE_WEEKLY !== '1') return;
  const head = await provider.getBlockNumber(), from = Math.max(0, head - Math.ceil(7 * 86400 / 3));
  const pairSet = new Set(pools.map(p => lk(p.address))), vol = {};
  for (let b = from; b <= head; b += 9000){
    const logs = await provider.getLogs({fromBlock: b, toBlock: Math.min(head, b + 8999), topics: [SWAP_TOPIC]});
    for (const l of logs){
      const p = pools.find(q => lk(q.address) === lk(l.address)); if (!p) continue;
      const x = ref[lk(p.a0)], y = ref[lk(p.a1)]; if (x == null || y == null) continue;
      const w = i => ethers.BigNumber.from('0x' + l.data.slice(2 + 64 * i, 66 + 64 * i));
      const who = await swapTrader(l, pairSet); if (!who) continue;
      vol[who] = (vol[who] || 0) + fl(w(0), p.t0.decimals) * x + fl(w(1), p.t1.decimals) * y;
    }
  }
  const top = Object.entries(vol).filter(([a]) => a !== lk(me)).sort((a, b) => b[1] - a[1]).slice(0, 10);
  state.topTenAt = now(); saveState();
  await weeklyReport(from, head, vol);
  if (!top.length) return;
  const got = A.badges && me !== ethers.constants.AddressZero ? await award(top.map(t => t[0]), 8, 'Top Ten') : [];
  await tg(`🏆 <b>Weekly Top 10 by swap volume</b>\n${top.map(([a, v], i) => `${i + 1}. ${short(a)} · ${usd(v)}${got.some(g => lk(g) === a) ? ' 🎖️' : ''}`).join('\n')}` + (got.length ? `\n${got.length} new Top Ten badge${got.length > 1 ? 's' : ''} awarded.` : ''));
}

/* Royal Herald: referrers with 3+ invitees who hold the Royal Swapper badge. Checked every 6 hours. */
async function heralds(){
  if (!A.social || !A.badges || me === ethers.constants.AddressZero) return;
  if (state.heraldAt && now() - state.heraldAt < 6 * 3600) return;
  state.heraldAt = now(); saveState();
  const so = new ethers.Contract(A.social, ABI.social, wallet), bdg = new ethers.Contract(A.badges, ABI.badges, provider);
  const n = (await so.referralCount()).toNumber(), traders = {};
  for (let s = 0; s < n; s += 500){
    const {users, refs} = await so.referrals(s, 500);
    for (let i = 0; i < users.length; i++){ try{ if (!(await bdg.balanceOf(users[i], 1)).isZero()) traders[lk(refs[i])] = (traders[lk(refs[i])] || 0) + 1; }catch(e){} }
  }
  const due = [];
  for (const [r, c] of Object.entries(traders)) if (c >= 3){ try{ if ((await so.balanceOf(r, 1)).isZero()) due.push(ethers.utils.getAddress(r)); }catch(e){} }
  if (!due.length) return;
  try{
    await send(`award Royal Herald to ${due.length}`, () => so.awardHerald(due.slice(0, 25)));
    for (const a of due.slice(0, 25)) await tg(`📯 <b>New Royal Herald</b>\n${short(a)} brought 3+ friends who trade on CavFi.`);
  }catch(e){ log('herald failed', (e.reason || e.message || '').slice(0, 100)); }
}

// ------------------------------------------------------------------ 4. weekly vote apply
async function applyVotes(){
  if (!A.vote || !A.farm || !wallet || me === ethers.constants.AddressZero) return;
  const v = new ethers.Contract(A.vote, ABI.vote, wallet);
  const [next, total] = await Promise.all([v.nextApply(), v.totalVotes()]);
  if (total.isZero() || now() < next.toNumber()) return;
  try{
    const tx = await send('apply farm votes', () => v.applyVotes());
    const f = new ethers.Contract(A.farm, ABI.farm, provider);
    const n = (await f.poolLength()).toNumber(), tot = (await f.totalAllocPoint()).toNumber() || 1;
    const lines = [];
    for (let pid = 0; pid < n; pid++){
      const info = await f.poolInfo(pid);
      const p = pools.find(q => lk(q.address) === lk(info.lpToken));
      const name = p ? `${p.t0.symbol}/${p.t1.symbol}` : short(info.lpToken);
      lines.push(`${esc(name)}: ${(info.allocPoint.toNumber() / tot * 100).toFixed(1)}%`);
    }
    await tg(`🗳️ <b>Farm votes applied</b>\nNew share of KingS rewards:\n${lines.join('\n')}` + (tx ? `\n<a href="${txUrl(tx.hash)}">transaction</a>` : ''));
  }catch(e){ log('apply votes failed:', (e.reason || e.message || '').slice(0, 100)); }
}

// ------------------------------------------------------------------ 5. CavFi Arena
// Rounds only get prices when someone calls poke(): the start price is the average of samples
// taken in a round's first 10 minutes, the end price of those in its last 10 minutes, and a token
// needs 3 samples in each window to win. The bot pokes every ARENA_POKE_SEC inside those windows
// only (each poke costs an L1 data fee), and settles finished rounds for the KingS tip.
const WINDOW = 600;
let arenaLastPoke = 0;
async function arena(){
  if (!CFG.arena || !A.arena || !wallet || me === ethers.constants.AddressZero) return;
  const c = new ethers.Contract(A.arena, ABI.arena, wallet);
  const [[ready, sid], cur] = await Promise.all([c.settleable(), c.currentRound()]);
  const t = (await provider.getBlock('latest')).timestamp;
  if (ready){
    try{
      const tx = await send(`arena settle round #${sid}`, () => c.settle());
      arenaLastPoke = t;
      if (tx){
        const rc = await provider.getTransactionReceipt(tx.hash);
        const ev = rc.logs.map(l => { try{ return c.interface.parseLog(l); }catch(e){ return null; } }).find(x => x && x.name === 'Settled');
        if (ev && !ev.args.pot.isZero()){
          const [toks] = await c.roundTokens(ev.args.id);
          const wins = [];
          for (let i = 0; i < toks.length; i++) if ((ev.args.winnerMask >> i) & 1) wins.push((await token(toks[i])).symbol);
          const pot = fmtN(fl(ev.args.pot, 18));
          if (ev.args.rolledOver){
            await tg(`🏟️ <b>Arena round #${ev.args.id}</b>: nobody backed ${wins.length ? esc(wins.join(' + ')) : 'a winner'}. The pot of ${pot} KingS rolls into the next round.`);
          } else {
            const ws = await arenaWinners(ev.args.id.toNumber(), rc.blockNumber).catch(e => { log('arena winners lookup failed:', e.message); return []; });
            const lines = ws.map(w => `• ${w.label}: ${fmtN(w.amount)} KingS`).join('\n');
            await tg(`🏆 <b>Arena round #${ev.args.id}</b>: ${esc(wins.join(' + '))} rose the most against DOGE.\n` +
              (ws.length ? `${ws.length === 1 ? 'One backer takes' : `${ws.length} backers share`} ${fmtN(ws.reduce((x, w) => x + w.amount, 0))} KingS:\n${lines}` : `Backers share ${pot} KingS.`) +
              `\nClaim on <a href="https://cavfi.com/arena.html">cavfi.com/arena.html</a> · <a href="${txUrl(tx.hash)}">transaction</a>`);
            if (ws.length){ (state.arenaWins ||= []).push({id: ev.args.id.toNumber(), at: now(), users: ws.map(w => w.user), sent: 0}); saveState(); }
          }
        }
      }
    }catch(e){ log('arena settle failed:', (e.reason || e.message || '').slice(0, 100)); }
    return;
  }
  const id = cur.id.toNumber(), start = Number(cur.start.toString()), end = Number(cur.end.toString());
  const inWindow = id === 0 || !cur.live || t < start + WINDOW || t + WINDOW >= end;
  if (!inWindow || t - arenaLastPoke < CFG.arenaPokeSec) return;
  try{ await send('arena poke', () => c.poke()); arenaLastPoke = t; }
  catch(e){ log('arena poke failed:', (e.reason || e.message || '').slice(0, 100)); }
}

// Winners of a settled round: every Staked event of that round on a winning token, summed per
// wallet and valued by the contract's own claimable() (0 once claimed). Logs are read in
// 9,999-block steps (the DogeOS RPC limit) from the round's start to the settle block.
const blockCache = {};
async function blockAt(ts, hi){
  let lo = Math.max(1, hi - 400000);
  const T = async b => blockCache[b] ??= (await provider.getBlock(b)).timestamp;
  if (await T(lo) > ts) return lo;
  while (hi - lo > 1){ const mid = Math.floor((lo + hi) / 2); if (await T(mid) < ts) lo = mid; else hi = mid; }
  return lo;
}
async function arenaWinners(id, endBlock){
  const c = new ethers.Contract(A.arena, ABI.arena, provider);
  const r = await c.getRound(id);
  if (!r.settled || r.winnerStake.isZero()) return [];
  const head = endBlock || await provider.getBlockNumber();
  const from = await blockAt(Number(r.start.toString()) - 60, head);
  const topic = c.interface.getEventTopic('Staked'), idT = ethers.utils.hexZeroPad(ethers.BigNumber.from(id).toHexString(), 32);
  const users = new Set();
  for (let b = from; b <= head; b += 9999){
    const logs = await provider.getLogs({address: A.arena, fromBlock: b, toBlock: Math.min(head, b + 9998), topics: [topic, idT]});
    for (const l of logs){ const e = c.interface.parseLog(l); if ((r.winnerMask >> e.args.idx.toNumber()) & 1) users.add(ethers.utils.getAddress(e.args.user)); }
  }
  const list = [...users];
  let names = list.map(() => '');
  if (A.names && list.length){ try{ names = await new ethers.Contract(A.names, ABI.names, provider).namesOf(list); }catch(e){} }
  const out = [];
  for (let i = 0; i < list.length; i++){
    const amount = fl(await c.claimable(id, list[i]), 18);
    out.push({user: list[i], amount, label: /^[a-z0-9-]{3,32}$/.test(names[i] || '') ? `${names[i]}.cav` : short(list[i])});
  }
  return out.sort((a, b) => b.amount - a.amount);
}
// Unclaimed winnings: a reminder in Telegram ARENA_REMIND_HOURS after the round (2 h and 24 h by
// default) for every winner who still hasn't claimed. Checked every 10 minutes. On first run it
// also picks up wins from the last 48 rounds, so older unclaimed pots get a reminder too.
let arenaRemindAt = 0;
async function arenaReminders(){
  if (!CFG.arena || !A.arena || now() - arenaRemindAt < 600) return;
  arenaRemindAt = now();
  const c = new ethers.Contract(A.arena, ABI.arena, provider);
  if (!state.arenaWinsScanned){
    const last = (await c.lastSettled()).toNumber(), have = new Set((state.arenaWins || []).map(w => w.id));
    for (let id = Math.max(1, last - 47); id <= last; id++){
      if (have.has(id)) continue;
      const r = await c.getRound(id);
      if (!r.settled || r.winnerStake.isZero()) continue;
      const ws = await arenaWinners(id);
      if (ws.some(w => w.amount > 0)) (state.arenaWins ||= []).push({id, at: Number(r.end.toString()), users: ws.map(w => w.user), sent: 0});
    }
    state.arenaWinsScanned = true; saveState();
  }
  const keep = [];
  for (const w of state.arenaWins || []){
    const age = (now() - w.at) / 3600, due = CFG.arenaRemindHours.filter(h => age >= h).length;
    if (due > w.sent){
      let names = w.users.map(() => '');
      if (A.names){ try{ names = await new ethers.Contract(A.names, ABI.names, provider).namesOf(w.users); }catch(e){} }
      const open = [];
      for (let i = 0; i < w.users.length; i++){ const a = fl(await c.claimable(w.id, w.users[i]), 18); if (a > 0) open.push(`• ${/^[a-z0-9-]{3,32}$/.test(names[i] || '') ? names[i] + '.cav' : short(w.users[i])}: ${fmtN(a)} KingS`); }
      if (!open.length) continue; // everyone claimed: forget this round
      await tg(`💰 <b>Unclaimed Arena winnings</b> from round #${w.id}:\n${open.join('\n')}\nClaim them on <a href="https://cavfi.com/arena.html">cavfi.com/arena.html</a>`);
      w.sent = due;
    }
    if (w.sent < CFG.arenaRemindHours.length) keep.push(w);
  }
  state.arenaWins = keep; saveState();
}

// Market noise: on a quiet testnet nobody trades, every Arena token ends a round at +0.00% and the
// round is a tie. In the middle of each round (never inside the start or end price windows) the bot
// makes ARENA_NOISE_TRADES small random swaps (0.5-2% of a pool, at most ARENA_NOISE_MAX_DOGE),
// buying or selling a randomly chosen Arena token against DOGE. Times, token and direction are random
// and the bot never looks at who staked on what.
const noise = { round: 0, plan: [] };
async function arenaNoise(){
  if (!CFG.arena || !CFG.arenaNoise || !A.arena || !wallet || me === ethers.constants.AddressZero) return;
  const c = new ethers.Contract(A.arena, ABI.arena, provider);
  const cur = await c.currentRound();
  if (!cur.live) return;
  const id = cur.id.toNumber(), start = Number(cur.start.toString()), end = Number(cur.end.toString());
  const t = (await provider.getBlock('latest')).timestamp;
  if (noise.round !== id){
    noise.round = id;
    const lo = Math.max(t + 30, start + WINDOW + 60), hi = end - WINDOW - 60;
    noise.plan = hi > lo ? Array.from({length: CFG.arenaNoiseTrades}, () => lo + Math.random() * (hi - lo)).sort((a, b) => a - b) : [];
    if (noise.plan.length) log(`arena noise: ${noise.plan.length} random trades planned for round #${id}`);
  }
  if (!noise.plan.length || t < noise.plan[0] || t + WINDOW + 30 >= end) return;
  noise.plan.shift();
  try{
    const [toks, pairs] = await c.roundTokens(id);
    const i = Math.floor(Math.random() * toks.length), tok = toks[i];
    const pair = new ethers.Contract(pairs[i], ABI.pair, provider);
    const [r0, r1] = await pair.getReserves();
    const dogeIs0 = lk(await pair.token0()) === lk(A.wdoge);
    const rW = dogeIs0 ? r0 : r1, rT = dogeIs0 ? r1 : r0;
    // small moves only: 0.2-0.6% of the pool moves the price about 0.4-1.2%, under the pool-fix
    // threshold and inside most people's slippage, so it never fights the rebalancer or a user's swap
    const pct = CFG.arenaNoiseMinPct + Math.random() * (CFG.arenaNoiseMaxPct - CFG.arenaNoiseMinPct);
    const bp = Math.max(1, Math.round(pct * 10000));
    const R = new ethers.Contract(A.router, ABI.router, wallet);
    const erc = new ethers.Contract(tok, ABI.erc20, wallet);
    const sym = (await token(tok)).symbol;
    // buy and sell the same DOGE value, so over time the bot's DOGE doesn't drain into tokens;
    // when the bot runs low on DOGE it prefers selling the tokens it already holds
    let dogeSize = rW.mul(bp).div(10000);
    const cap = ethers.utils.parseEther(String(CFG.arenaNoiseMaxDoge));
    if (dogeSize.gt(cap)) dogeSize = cap;
    const sellAmt = rT.mul(dogeSize).div(rW);
    const canSell = (await erc.balanceOf(me)).gte(sellAmt) && !sellAmt.isZero();
    const low = fl(await provider.getBalance(me), 18) < CFG.arenaNoiseLowDoge;
    const sell = canSell && Math.random() < (low ? 0.85 : 0.5);
    const deadline = t + 600;
    if (sell){
      const out = (await R.getAmountsOut(sellAmt, [tok, A.wdoge]))[1];
      await ensureAllowance(tok, A.router, sellAmt);
      await send(`arena noise: sell ${(pct*100).toFixed(1)}% of ${sym} pool`, () => R.swapExactTokensForETH(sellAmt, out.mul(97).div(100), [tok, A.wdoge], me, deadline));
    } else {
      const dogeIn = dogeSize;
      const spare = (await provider.getBalance(me)).sub(ethers.utils.parseEther(CFG.gasReserve)).sub(ethers.utils.parseEther('5'));
      if (dogeIn.gt(spare) || dogeIn.isZero()) { log('arena noise: skipped, bot is low on DOGE'); return; }
      const out = (await R.getAmountsOut(dogeIn, [A.wdoge, tok]))[1];
      await send(`arena noise: buy ${sym} with ${fmtN(fl(dogeIn, 18))} DOGE`, () => R.swapExactETHForTokens(out.mul(97).div(100), [A.wdoge, tok], me, deadline, {value: dogeIn}));
    }
  }catch(e){ log('arena noise failed:', (e.reason || e.message || '').slice(0, 100)); }
}

// ------------------------------------------------------------------ 3. notifications
async function notify(){
  const head = await provider.getBlockNumber();
  if (state.block == null){ state.block = head; saveState(); return; }   // start from now on first run
  const from = state.block + 1; if (from > head) return;
  const to = Math.min(head, from + 9000);
  const pairSet = new Set(pools.map(p => lk(p.address)));
  if (A.launch){
    const iface = new ethers.utils.Interface(ABI.launch);
    const logs = await provider.getLogs({address: A.launch, fromBlock: from, toBlock: to, topics: [[iface.getEventTopic('Launched'), iface.getEventTopic('Graduated')]]});
    for (const l of logs){
      const e = iface.parseLog(l);
      if (e.name === 'Launched') await tg(`🚀 <b>New launch: ${esc(e.args.name)} ($${esc(e.args.symbol)})</b>\nby ${short(e.args.creator)} · graduates at ${fmtN(fl(e.args.target, 18))} DOGE\n<a href="https://cavfi.com/#launch">Trade it on CavFi</a>`);
      else { const t = await token(e.args.token); await tg(`🎓 <b>$${esc(t.symbol)} graduated!</b>\n${fmtN(fl(e.args.doge, 18))} DOGE + ${fmtN(fl(e.args.amount, 18))} ${esc(t.symbol)} are now a CavFi pool with burned LP.\n<a href="${txUrl(l.transactionHash)}">transaction</a>`); }
    }
  }
  if ((CFG.notifySwapUsd > 0 || A.badges) && pools.length){
    const logs = await provider.getLogs({fromBlock: from, toBlock: to, topics: [SWAP_TOPIC]});
    const seen = new Set(), swappers = [];
    if (A.badges) for (const l of logs){ if (pools.some(q => lk(q.address) === lk(l.address))){ const w = await swapTrader(l, pairSet); if (w) swappers.push(w); } }
    const newSw = await award(swappers, 1, 'Royal Swapper');
    for (const a of newSw) await tg(`🎖️ <b>New Royal Swapper</b>\n${short(a)} made their first CavFi swap and earned a badge.`);
    for (const l of (CFG.notifySwapUsd > 0 ? logs : [])){
      const p = pools.find(q => lk(q.address) === lk(l.address)); if (!p || seen.has(l.transactionHash)) continue;
      const w = i => ethers.BigNumber.from('0x' + l.data.slice(2 + 64 * i, 66 + 64 * i));
      const i0 = fl(w(0), p.t0.decimals), i1 = fl(w(1), p.t1.decimals), o0 = fl(w(2), p.t0.decimals), o1 = fl(w(3), p.t1.decimals);
      const x = ref[lk(p.a0)], y = ref[lk(p.a1)]; if (x == null || y == null) continue;
      const v = i0 * x + i1 * y; if (v < CFG.notifySwapUsd) continue;
      seen.add(l.transactionHash);
      const [inT, inN, outT, outN] = i0 > 0 ? [p.t0, i0, p.t1, o1] : [p.t1, i1, p.t0, o0];
      const toAddr = '0x' + l.topics[2].slice(26);
      if (pairSet.has(lk(toAddr))) continue; // a middle hop; the last hop reports the trade
      await tg(`🐳 <b>Big swap ${usd(v)}</b>\n${fmtN(inN)} ${esc(inT.symbol)} → ${fmtN(outN)} ${esc(outT.symbol)}\n<a href="${txUrl(l.transactionHash)}">transaction</a>`);
    }
  }
  state.block = to; saveState();
}

// ------------------------------------------------------------------ main
const LOCK = path.join(HERE, 'bot.lock');
function takeLock(){
  try{
    const pid = Number(fs.readFileSync(LOCK, 'utf8'));
    if (pid && pid !== process.pid){ try{ process.kill(pid, 0); console.error(`Another CavFi bot is already running (pid ${pid}). Stop it first (stop-bot.ps1) or close its window.`); process.exit(3); }catch(e){ /* stale lock */ } }
  }catch(e){}
  fs.writeFileSync(LOCK, String(process.pid));
  const drop = () => { try{ if (Number(fs.readFileSync(LOCK, 'utf8')) === process.pid) fs.unlinkSync(LOCK); }catch(e){} };
  process.on('exit', drop);
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGBREAK']) process.on(sig, () => { drop(); process.exit(0); });
}

async function main(){
  if (!CFG.once) takeLock();
  const net = await provider.getNetwork();
  if (net.chainId !== CFG.chainId) throw new Error(`RPC is on chain ${net.chainId}, expected ${CFG.chainId}`);
  let pk = env('PRIVATE_KEY', '');
  const needKey = CFG.fillLimits || CFG.rebalance;
  if (needKey && !pk && !CFG.dryRun) pk = await askHidden('Bot wallet private key (input hidden): ');
  if (pk){ wallet = new ethers.Wallet(pk.startsWith('0x') ? pk : '0x' + pk, provider); me = wallet.address; }
  else { wallet = provider; me = ethers.constants.AddressZero; }
  if (me === ethers.constants.AddressZero && !CFG.dryRun){ CFG.fillLimits = false; CFG.rebalance = false; }
  log(`CavFi bot on chain ${CFG.chainId} · wallet ${me === ethers.constants.AddressZero ? 'none (notify only)' : me}`);
  log(`arena: ${CFG.arena && A.arena ? `on (poke every ${CFG.arenaPokeSec}s in the price windows${CFG.arenaNoise ? `, ${CFG.arenaNoiseTrades} random trades a round` : ''})` : 'off'}`);
  log(`limit fills: ${CFG.fillLimits ? 'on' : 'off'} · rebalance: ${CFG.rebalance ? `on (≥${CFG.minDev*100}% off, ≤ ${usd(CFG.maxUsd)} a trade)` : 'off'} · telegram: ${CFG.tgToken && CFG.tgChat ? 'on' : 'off'}${CFG.dryRun ? ' · DRY RUN' : ''}`);
  if (me !== ethers.constants.AddressZero) log('balance', fmtN(fl(await provider.getBalance(me), 18)), 'DOGE');
  await tg(`🐶 <b>CavFi bot started</b>${me !== ethers.constants.AddressZero ? `\nwallet ${short(me)}` : ''}`);
  let errors = 0;
  for (;;){
    try{
      await loadPools();
      await fillLimits();
      await rebalance();
      await applyVotes();
      await arena();
      await arenaNoise();
      await arenaReminders();
      await weeklyTopTen();
      await heralds();
      await notify();
      errors = 0;
    }catch(e){
      errors++; log('round failed:', (e.reason || e.message || String(e)).slice(0, 160));
      if (errors === 5) await tg('⚠️ CavFi bot: 5 failed rounds in a row. Check the RPC or the bot wallet.');
    }
    if (CFG.once) break;
    await sleep(CFG.interval);
  }
}
main().catch(e => { console.error('Fatal:', e.message); process.exit(1); });
