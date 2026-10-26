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
import { createRequire } from 'node:module';

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
  dca: env('DCA', '1') === '1',
  quests: env('QUESTS', '1') === '1',
  questsSource: env('QUESTS_SOURCE', 'explorer'), // 'explorer' (Blockscout API) or 'rpc' (scan blocks; local tests)
  questsDelaySec: Number(env('QUESTS_DELAY_SEC', '300')),
  raffle: env('RAFFLE', '1') === '1',
  alerts: env('ALERTS', '1') === '1',
  predict: env('PREDICT', '1') === '1',
  predictDaily: env('PREDICT_DAILY', '1') === '1',
  predictWeekly: env('PREDICT_WEEKLY', '1') === '1',
  predictHourly: env('PREDICT_HOURLY', '1') === '1',
  predictHourlyPostMin: Number(env('PREDICT_HOURLY_POST_MIN', '1000')),
  predictPrice: Number(env('PREDICT_PRICE', '0')), // tests only: use this DOGE/USD price instead of the exchanges
  duels: env('DUELS', '1') === '1',
  watchMax: Number(env('WATCH_MAX', '3')),
  gmRemindHour: Number(env('GM_REMIND_HOUR_UTC', '18')),
  digest: env('DIGEST', '1') === '1',
  digestHour: Number(env('DIGEST_HOUR_UTC', '6')),
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
  names: ['function namesOf(address[]) view returns (string[])', 'function resolve(string) view returns (address)'],
  gm: ['function info(address) view returns (bool gmToday, bool gnToday, uint256 streak, uint256 best, uint256 gms, uint256 gns, bool pup, uint256 nextDayAt)'],
  qinfo: ['function info(address) view returns (uint256 streak, uint256 best, uint256 fullDays, uint256 quests, bool badge, uint8 yesterday)'],
  predict: ['function create(string question, uint256 strike, uint64 closeAt, uint64 resolveAt) returns (uint256)', 'function resolve(uint256 id, uint256 price)',
            'function oracle() view returns (address)', 'function owner() view returns (address)', 'function count() view returns (uint256)',
            'function page(uint256 start, uint256 n) view returns (uint256[] ids, tuple(string question, uint64 closeAt, uint64 resolveAt, uint8 state, bool yesWon, uint256 strike, uint256 price, uint256 yesPool, uint256 noPool)[] items)',
            'function yesOf(uint256, address) view returns (uint256)', 'function noOf(uint256, address) view returns (uint256)', 'function claimable(uint256, address) view returns (uint256)'],
  duel: ['function page(uint256 start, uint256 n) view returns (uint256[] ids, tuple(address maker, address taker, address invited, address winner, uint64 roundId, uint8 makerIdx, uint8 takerIdx, uint8 state, uint256 stake)[] items)',
         'function settle(uint256 id)', 'function cancel(uint256 id)', 'event Settled(uint256 indexed id, address winner, uint256 paid)'],
  dca: ['function count() view returns (uint256)', 'function due(uint256 start, uint256 n) view returns (uint256[])', 'function execute(uint256 id, address[] path) returns (uint256)',
        'function get(uint256 id) view returns (tuple(address owner, bool active, bool nativeIn, bool nativeOut, uint32 buysTotal, uint32 buysLeft, uint32 interval, uint64 nextAt, address tokenIn, address tokenOut, uint256 perBuy, uint256 minOutPerBuy, uint256 spent, uint256 received))',
        'function keeper(address) view returns (bool)'],
  quests: ['function record(uint32 day, address[] users, uint8[] done)', 'function attester(address) view returns (bool)', 'function doneOf(address, uint32) view returns (uint8)',
           'event Questmaster(address indexed who)'],
  raffle: ['function current() view returns (uint256 id, uint64 start, uint64 end, uint256 totalTickets, uint256 playerCount, uint256 pot, uint64 drawBlock)',
           'function addTickets(address[] users, uint256[] counts)', 'function close()', 'function draw()', 'function attester(address) view returns (bool)',
           'event Drawn(uint256 indexed id, address[3] winners, uint256[3] prizes, uint256 pot)'],
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
// bot-state.json is written to a temp file and renamed, so a crash or power cut never leaves it half-written.
// If it is unreadable anyway, the last good copy (bot-state.json.bak) is used, else the bot starts fresh.
function loadState(){
  for (const f of [STATE_FILE, STATE_FILE + '.bak']){
    try{ if (fs.existsSync(f)){ const t = fs.readFileSync(f, 'utf8').replace(/\0/g, '').trim(); if (t){ const j = JSON.parse(t); if (f !== STATE_FILE) console.log('bot-state.json was damaged, using bot-state.json.bak'); return j; } } }
    catch(e){ console.log(`${path.basename(f)} is damaged (${e.message.slice(0, 60)}), ignoring it`); try{ fs.copyFileSync(f, f + '.broken'); }catch(_){} }
  }
  return {};
}
const state = loadState();
let stateBakAt = 0;
const saveState = () => {
  const tmp = STATE_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(state, null, 1));
  fs.renameSync(tmp, STATE_FILE);
  if (Date.now() - stateBakAt > 600000){ stateBakAt = Date.now(); try{ fs.copyFileSync(STATE_FILE, STATE_FILE + '.bak'); }catch(e){} }
};

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
            for (const w of ws) await notifyUser(w.user, `🏆 <b>You won Arena round #${ev.args.id}!</b> ${esc(wins.join(' + '))} rose the most. Claim <b>${fmtN(w.amount)} KingS</b> on <a href="https://cavfi.com/arena.html">cavfi.com/arena.html</a>`);
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
      for (let i = 0; i < w.users.length; i++){ const a = fl(await c.claimable(w.id, w.users[i]), 18); if (a > 0) await notifyUser(w.users[i], `💰 You still have <b>${fmtN(a)} KingS</b> to claim from Arena round #${w.id}: <a href="https://cavfi.com/arena.html">cavfi.com/arena.html</a>`); if (a > 0) open.push(`• ${/^[a-z0-9-]{3,32}$/.test(names[i] || '') ? names[i] + '.cav' : short(w.users[i])}: ${fmtN(a)} KingS`); }
      if (!open.length) continue; // everyone claimed: forget this round
      await tg(`💰 <b>Unclaimed Arena winnings</b> from round #${w.id}:\n${open.join('\n')}\nClaim them on <a href="https://cavfi.com/arena.html">cavfi.com/arena.html</a>`);
      w.sent = due;
    }
    if (w.sent < CFG.arenaRemindHours.length) keep.push(w);
  }
  state.arenaWins = keep; saveState();
}

// ------------------------------------------------------------------ 6. auto-buy (DCA) keeper
// Runs every due part of every auto-buy plan through the best CavFi route (earns 0.1% of the part).
// A part whose best route pays less than the plan's floor is skipped and retried 10 minutes later.
const dcaSkip = {};
async function dcaKeeper(){
  if (!CFG.dca || !A.dca || !wallet || me === ethers.constants.AddressZero) return;
  const c = new ethers.Contract(A.dca, ABI.dca, wallet);
  if (!state.dcaKeeperOk){ if (!(await c.keeper(me))){ log('dca: this wallet is not a keeper of the auto-buy contract, skipping'); CFG.dca = false; return; } state.dcaKeeperOk = true; }
  const n = (await c.count()).toNumber(); if (!n) return;
  for (let s = 0; s < n; s += 200){
    const ids = await c.due(s, 200);
    for (const idB of ids){
      const id = idB.toNumber();
      if (dcaSkip[id] && now() < dcaSkip[id]) continue;
      try{
        const p = await c.get(id);
        const swapIn = p.perBuy.sub(p.perBuy.mul(10).div(10000));
        const best = await bestRoute(p.tokenIn, p.tokenOut, swapIn);
        if (!best || best.out.lt(p.minOutPerBuy)){ dcaSkip[id] = now() + 600; log(`dca #${id}: price below the plan's floor, retry in 10 min`); continue; }
        const dtx = await send(`dca #${id}: buy ${p.buysTotal - p.buysLeft + 1}/${p.buysTotal}`, () => c.execute(id, best.path));
        if (dtx && watchersOf(p.owner).length){
          const ti = await token(p.tokenIn), to = await token(p.tokenOut);
          await notifyUser(p.owner, `🔁 <b>Auto-buy #${id}</b>: buy ${p.buysTotal - p.buysLeft + 1} of ${p.buysTotal} done, ${fmtN(fl(p.perBuy, ti.decimals))} ${esc(ti.symbol)} → ~${fmtN(fl(best.out, to.decimals))} ${esc(to.symbol)}.`);
        }
        if (p.buysLeft === 1){
          const ti = await token(p.tokenIn), to = await token(p.tokenOut);
          await tg(`🔁 <b>Auto-buy #${id} finished</b>\n${p.buysTotal} buys of ${fmtN(fl(p.perBuy, ti.decimals))} ${esc(ti.symbol)} → ${esc(to.symbol)} for ${short(p.owner)}.`);
        }
      }catch(e){ dcaSkip[id] = now() + 600; log(`dca #${id} failed:`, (e.reason || e.message || '').slice(0, 100)); }
    }
  }
}

// ------------------------------------------------------------------ 7. daily quests + Royal Raffle tickets
// After a UTC day ends (+ QUESTS_DELAY_SEC), read that day's transactions to every quest contract,
// check each wallet against the day's 3 quests (rules shared with the site in site/quests-rules.js),
// record the result on-chain and give one raffle ticket per quest done.
const requireLocal = createRequire(import.meta.url);
let QR = null;
function questRules(){
  if (QR) return QR;
  const f = path.join(path.dirname(CFG.addresses), 'quests-rules.js');
  QR = requireLocal(f);
  return QR;
}
async function dayTxsExplorer(contract, from, to){
  const out = [];
  let url = `${CFG.explorer}/api/v2/addresses/${contract}/transactions?filter=to`;
  for (let page = 0; page < 60; page++){
    const r = await fetch(url).then(x => x.json());
    let older = false;
    for (const t of r.items || []){
      const ts = Math.floor(Date.parse(t.timestamp) / 1000);
      if (ts >= to) continue;
      if (ts < from){ older = true; break; }
      out.push({from: t.from && t.from.hash, to: t.to && t.to.hash, input: t.raw_input || '', ok: t.status === 'ok' || t.result === 'success', ts});
    }
    if (older || !r.next_page_params) break;
    url = `${CFG.explorer}/api/v2/addresses/${contract}/transactions?filter=to&` + new URLSearchParams(r.next_page_params);
  }
  return out;
}
async function dayTxsRpc(contracts, from, to){
  const set = new Set(contracts), out = [];
  const head = await provider.getBlockNumber();
  for (let b = head; b >= 0; b--){
    const blk = await provider.getBlockWithTransactions(b);
    if (blk.timestamp < from) break;
    if (blk.timestamp >= to) continue;
    for (const t of blk.transactions){
      if (!t.to || !set.has(lk(t.to))) continue;
      const rc = await provider.getTransactionReceipt(t.hash);
      out.push({from: t.from, to: t.to, input: t.data, ok: rc.status === 1, ts: blk.timestamp});
    }
  }
  return out;
}
let questsAt = 0;
async function questsDaily(){
  if (!CFG.quests || !A.quests || !wallet || me === ethers.constants.AddressZero || now() - questsAt < 120) return;
  questsAt = now();
  const chainNow = (await provider.getBlock('latest')).timestamp;   // same clock as the contract's today()
  const last = Math.floor((chainNow - CFG.questsDelaySec) / 86400) - 1; // the last day that has fully ended
  if (state.questsDay != null && state.questsDay >= last) return;
  // catch up on days missed while the bot was off (at most 7; the contract accepts 30 days back)
  const day = state.questsDay == null ? last : Math.max(state.questsDay + 1, last - 6);
  const q = new ethers.Contract(A.quests, ABI.quests, wallet);
  if (!(await q.attester(me))){ log('quests: this wallet is not an attester of the quests contract, skipping'); CFG.quests = false; return; }
  const R = questRules(), from = day * 86400, to = from + 86400;
  const contracts = R.contracts(A);
  const txs = CFG.questsSource === 'rpc' ? await dayTxsRpc(contracts, from, to)
    : (await Promise.all(contracts.map(c => dayTxsExplorer(c, from, to)))).flat();
  const by = {};
  for (const t of txs) if (t.from) (by[ethers.utils.getAddress(t.from)] ||= []).push(t);
  delete by[ethers.utils.getAddress(me)]; // the bot itself doesn't play
  const users = [], done = [];
  for (const [u, list] of Object.entries(by)){ const ev = R.evaluate(list, A, day); if (ev.count > 0){ users.push(u); done.push(ev.count); } }
  log(`quests: day ${day} (${new Date(from * 1000).toISOString().slice(0, 10)}): ${users.length} wallets did quests, ${done.filter(d => d === 3).length} finished all 3`);
  const masters = [];
  for (let i = 0; i < users.length; i += 40){
    const u = users.slice(i, i + 40), d = done.slice(i, i + 40);
    const tx = await send(`quests: record day ${day} (${u.length} wallets)`, () => q.record(day, u, d));
    if (tx){ const rc = await provider.getTransactionReceipt(tx.hash); for (const l of rc.logs){ try{ const e = q.interface.parseLog(l); if (e.name === 'Questmaster') masters.push(e.args.who); }catch(_){} } }
  }
  // raffle tickets: one per quest
  if (CFG.raffle && A.raffle && users.length){
    try{
      await raffleKeeper(); // close/draw an ended round first, so tickets land in an open one
      const r = new ethers.Contract(A.raffle, ABI.raffle, wallet), cur = await r.current();
      const t = (await provider.getBlock('latest')).timestamp;
      if (await r.attester(me) && t < Number(cur.end.toString()) && cur.drawBlock.isZero()){
        for (let i = 0; i < users.length; i += 40) await send(`raffle: ${users.slice(i, i + 40).length} wallets get tickets`, () => r.addTickets(users.slice(i, i + 40), done.slice(i, i + 40)));
      } else log('raffle: round not open for tickets right now');
    }catch(e){ log('raffle tickets failed:', (e.reason || e.message || '').slice(0, 100)); }
  }
  state.questsDay = day; saveState();
  for (let i = 0; i < users.length; i++) if (watchersOf(users[i]).length)
    await notifyUser(users[i], `📜 <b>Daily quests ${new Date(from * 1000).toISOString().slice(0, 10)}</b>: you did ${done[i]} of 3${done[i] === 3 ? ' 🔥 full day' : ''}, and got ${done[i]} raffle ticket${done[i] === 1 ? '' : 's'}.`);
  if (day < last) questsAt = 0; // more days to catch up: next loop continues right away
  if (users.length){
    await tg(`📜 <b>Daily quests, ${new Date(from * 1000).toISOString().slice(0, 10)}</b>\n${users.length} wallet${users.length === 1 ? '' : 's'} did quests, ${done.filter(d => d === 3).length} finished all 3.` +
      (CFG.raffle && A.raffle ? `\n🎟️ ${done.reduce((a, b) => a + b, 0)} Royal Raffle tickets given out.` : '') +
      (masters.length ? `\n🏅 New Questmaster: ${masters.map(short).join(', ')}` : '') + `\nToday's quests: <a href="https://cavfi.com">cavfi.com</a>`);
  }
}
let raffleAt = 0;
async function raffleKeeper(){
  if (!CFG.raffle || !A.raffle || !wallet || me === ethers.constants.AddressZero) return;
  const r = new ethers.Contract(A.raffle, ABI.raffle, wallet), cur = await r.current();
  const blk = await provider.getBlock('latest');
  if (blk.timestamp < Number(cur.end.toString())) return;
  if (cur.drawBlock.isZero()){ await send(`raffle: close week #${cur.id}`, () => r.close()); return; }
  if (blk.number <= cur.drawBlock.toNumber()) return;
  const tx = await send(`raffle: draw week #${cur.id}`, () => r.draw());
  if (!tx) return;
  const rc = await provider.getTransactionReceipt(tx.hash);
  const ev = rc.logs.map(l => { try{ return r.interface.parseLog(l); }catch(e){ return null; } }).find(x => x && x.name === 'Drawn');
  if (!ev) return; // the chosen block was too old; a new one was picked
  const ws = ev.args.winners.map((w, i) => ({w, p: fl(ev.args.prizes[i], 18)})).filter(x => x.w !== ethers.constants.AddressZero && x.p > 0);
  let names = ws.map(() => '');
  if (A.names && ws.length){ try{ names = await new ethers.Contract(A.names, ABI.names, provider).namesOf(ws.map(x => x.w)); }catch(e){} }
  for (const x of ws) await notifyUser(x.w, `🎟️ <b>You won ${fmtN(x.p)} KingS in the Royal Raffle</b> (week #${ev.args.id})! The prize is already in your wallet.`);
  await tg(ws.length
    ? `🎟️ <b>Royal Raffle week #${ev.args.id} drawn!</b>\n${ws.map((x, i) => `${['🥇', '🥈', '🥉'][i]} ${/^[a-z0-9-]{3,32}$/.test(names[i] || '') ? names[i] + '.cav' : short(x.w)}: ${fmtN(x.p)} KingS`).join('\n')}\nPrizes are already in their wallets. New week, new tickets: do your daily quests on <a href="https://cavfi.com">cavfi.com</a>`
    : `🎟️ <b>Royal Raffle week #${ev.args.id}</b>: no tickets this week, the pot of ${fmtN(fl(ev.args.pot, 18))} KingS rolls into next week.`);
}

// ------------------------------------------------------------------ 8. Telegram price alerts
// Anyone can message the bot: /price KingS · /alert KingS above 0.00003 · /alerts · /cancel 2 · /help
// Prices are the same market prices the bot uses for pool fixes (USD, from the CavFi pools).
const ALERT_MAX = 10;
async function tgReply(chat, html, markup){
  if (!CFG.tgToken) return;
  try{ await fetch(`${CFG.tgApi}/bot${CFG.tgToken}/sendMessage`, {method:'POST', headers:{'content-type':'application/json'},
    body: JSON.stringify({chat_id: chat, text: html, parse_mode: 'HTML', disable_web_page_preview: true, ...(markup ? {reply_markup: markup} : {})})}); }catch(e){}
}
// Telegram Mini App: the bot's menu button and an "Open CavFi" button open the site inside Telegram.
const MINI_APP_URL = 'https://cavfi.com/?tg=1';
const openBtn = priv => ({inline_keyboard: [[priv ? {text: '👑 Open CavFi', web_app: {url: MINI_APP_URL}} : {text: '👑 Open CavFi', url: 'https://cavfi.com'}]]});
function findToken(sym){
  const s = String(sym || '').toLowerCase().replace(/^\$/, '');
  if (s === 'doge' || s === 'wdoge') return tokens[lk(A.wdoge)];
  const all = Object.values(tokens).filter(t => t.symbol.toLowerCase() === s || (s === 'usdt' && t.symbol === 'cUSDT') || (s === 'usdc' && t.symbol === 'cUSDC'));
  return all.sort((a, b) => (ref[lk(b.address)] ? 1 : 0) - (ref[lk(a.address)] ? 1 : 0))[0] || null;
}
const usdStr = v => v == null ? '?' : '$' + (v >= 1 ? v.toLocaleString('en-US', {maximumFractionDigits: 4}) : v.toLocaleString('en-US', {maximumSignificantDigits: 4, maximumFractionDigits: 20}));
async function alertsPoll(){
  if (!CFG.alerts || !CFG.tgToken) return;
  let r;
  try{ r = await fetch(`${CFG.tgApi}/bot${CFG.tgToken}/getUpdates?timeout=0&offset=${(state.tgOffset || 0) + 1}&allowed_updates=["message"]`).then(x => x.json()); }catch(e){ return; }
  if (!r || !r.ok) return;
  for (const u of r.result || []){
    state.tgOffset = Math.max(state.tgOffset || 0, u.update_id);
    const m = u.message; if (!m || !m.text || !m.chat) continue;
    const chat = m.chat.id, parts = m.text.trim().split(/\s+/), cmd = parts[0].toLowerCase().replace(/@.*$/, ''), priv = m.chat.type === 'private';
    const mine = (state.alerts ||= []).filter(a => a.chat === chat);
    if (cmd === '/start' && /^w(0x)?[0-9a-fA-F]{40}$/.test(parts[1] || '')){
      await watchAdd(chat, parts[1].slice(1));
    } else if (cmd === '/watch'){
      if (!parts[1]) await tgReply(chat, 'Usage: /watch kingdoge.cav  or  /watch 0x...');
      else await watchAdd(chat, parts[1]);
    } else if (cmd === '/unwatch'){
      const mine2 = (state.watch || []).filter(w => w.chat === chat);
      const addr = parts[1] ? await resolveWho(parts[1]) : (mine2.length === 1 ? mine2[0].addr : null);
      if (!addr) await tgReply(chat, mine2.length ? `Which one? ${mine2.map(w => '/unwatch ' + (w.label.endsWith('.cav') ? w.label : w.addr)).join('  ')}` : 'You follow no wallets.');
      else { state.watch = (state.watch || []).filter(w => !(w.chat === chat && lk(w.addr) === lk(addr))); await tgReply(chat, 'Stopped following that wallet.'); }
    } else if (cmd === '/me'){
      await watchSummary(chat);
    } else if (['/arena', '/markets', '/duels', '/quests', '/raffle', '/today'].includes(cmd)){
      const f = {'/arena': arenaText, '/markets': marketsText, '/duels': duelsText, '/quests': questsText, '/raffle': raffleText}[cmd];
      const txt = f ? await f() : (await Promise.all([questsText(), marketsText(), arenaText(), duelsText(), raffleText()])).filter(Boolean).join('\n\n');
      await tgReply(chat, txt || 'Nothing to show right now.');
    } else if (cmd === '/app' || cmd === '/open'){
      await tgReply(chat, '👑 CavFi: swap, the Arena, DOGE price markets, duels and more.', openBtn(priv));
    } else if (cmd === '/start' || cmd === '/help'){
      await tgReply(chat, `🐶 <b>CavFi bot</b>\n/app: open CavFi right here in Telegram\n<b>Your wallet</b>\n/watch kingdoge.cav (or 0x...): private messages for Arena wins, unclaimed winnings, auto-buys, quests, raffle prizes, predictions, duels and gm streak reminders\n/me: your followed wallets\n/unwatch: stop\n\n<b>CavFi today</b>\n/today: everything below in one message\n/markets: open DOGE price markets\n/arena: the current Arena round\n/duels: open duels\n/quests: today's quests\n/raffle: this week's raffle\n\n<b>Prices</b>\n/price KingS: current price\n/alert KingS above 0.00003: tell me when KingS goes above $0.00003\n/alert DOGE below 0.05\n/alerts: your alerts\n/cancel 2: remove alert 2\n\nEverything runs on the DogeOS testnet (testnet tokens, no real value). Token prices come from the CavFi pools; prediction markets use the DOGE price from Binance.`, openBtn(priv));
    } else if (cmd === '/price'){
      const t = findToken(parts[1]);
      await tgReply(chat, t ? `${esc(t.symbol)}: <b>${usdStr(ref[lk(t.address)])}</b>${ref[lk(A.wdoge)] && lk(t.address) !== lk(A.wdoge) && ref[lk(t.address)] ? ` (${(ref[lk(t.address)] / ref[lk(A.wdoge)]).toPrecision(4)} DOGE)` : ''}` : 'Unknown token. Try /price KingS, /price DOGE or /price RPUP.');
    } else if (cmd === '/alert'){
      const t = findToken(parts[1]), dir = (parts[2] || '').toLowerCase(), price = Number(String(parts[3] || '').replace(',', '.').replace(/^\$/, ''));
      if (!t || !['above', 'below'].includes(dir) || !(price > 0)) await tgReply(chat, 'Usage: /alert KingS above 0.00003  (or below)');
      else if (mine.length >= ALERT_MAX) await tgReply(chat, `You already have ${ALERT_MAX} alerts. Remove one with /cancel.`);
      else {
        const id = (state.alertSeq = (state.alertSeq || 0) + 1);
        state.alerts.push({id, chat, addr: t.address, sym: t.symbol, dir, price});
        await tgReply(chat, `✅ Alert ${id}: I'll tell you when ${esc(t.symbol)} goes ${dir} ${usdStr(price)}. Now: ${usdStr(ref[lk(t.address)])}.`);
      }
    } else if (cmd === '/alerts'){
      await tgReply(chat, mine.length ? mine.map(a => `${a.id}. ${esc(a.sym)} ${a.dir} ${usdStr(a.price)}`).join('\n') : 'No alerts yet. Example: /alert KingS above 0.00003');
    } else if (cmd === '/cancel'){
      const id = Number(parts[1]), before = state.alerts.length;
      state.alerts = state.alerts.filter(a => !(a.chat === chat && a.id === id));
      await tgReply(chat, state.alerts.length < before ? `Alert ${id} removed.` : 'No such alert. See /alerts.');
    }
  }
  // fire alerts
  const keep = [];
  for (const a of state.alerts || []){
    const v = ref[lk(a.addr)];
    if (v != null && ((a.dir === 'above' && v >= a.price) || (a.dir === 'below' && v <= a.price))){
      await tgReply(a.chat, `🔔 <b>${esc(a.sym)} is ${a.dir} ${usdStr(a.price)}</b>\nNow ${usdStr(v)}. Trade on <a href="https://cavfi.com">cavfi.com</a>`);
    } else keep.push(a);
  }
  state.alerts = keep; saveState();
}

// ------------------------------------------------------------------ 9. Personal notifications (/watch)
// Anyone can tell the bot which wallets to follow: /watch kingdoge.cav or /watch 0x...  (at most WATCH_MAX a chat).
// The site's "Telegram alerts" button opens t.me/<bot>?start=w<address>, which does the same in one tap.
// Followed wallets get a private message for Arena wins, unclaimed winnings, auto-buys, quest results,
// raffle prizes, prediction results, duel results, and a reminder when their gm streak is about to break.
const watchersOf = addr => (state.watch || []).filter(w => lk(w.addr) === lk(addr));
async function notifyUser(addr, html){
  for (const w of watchersOf(addr)) await tgReply(w.chat, `${html}\n<i>${esc(w.label)}</i> · /unwatch to stop`);
}
async function labelOf(addr){
  if (A.names){ try{ const [n] = await new ethers.Contract(A.names, ABI.names, provider).namesOf([addr]); if (/^[a-z0-9-]{3,32}$/.test(n || '')) return n + '.cav'; }catch(e){} }
  return short(addr);
}
async function resolveWho(s){
  s = String(s || '').trim().toLowerCase();
  if (/^(0x)?[0-9a-f]{40}$/.test(s)) return ethers.utils.getAddress(s.startsWith('0x') ? s : '0x' + s);
  const label = s.replace(/\.cav$/, '');
  if (A.names && /^[a-z0-9-]{3,32}$/.test(label)){
    try{ const a = await new ethers.Contract(A.names, ABI.names, provider).resolve(label); if (a !== ethers.constants.AddressZero) return a; }catch(e){}
  }
  return null;
}
async function watchAdd(chat, who){
  const addr = await resolveWho(who);
  if (!addr) return tgReply(chat, 'I could not find that wallet. Use a .cav name (kingdoge.cav) or a 0x address.');
  const mine = (state.watch ||= []).filter(w => w.chat === chat);
  if (mine.some(w => lk(w.addr) === lk(addr))) return tgReply(chat, `You already follow ${esc(await labelOf(addr))}. See /me.`);
  if (mine.length >= CFG.watchMax) return tgReply(chat, `You can follow up to ${CFG.watchMax} wallets. Remove one with /unwatch.`);
  const label = await labelOf(addr);
  state.watch.push({chat, addr, label}); saveState();
  await tgReply(chat, `✅ Following <b>${esc(label)}</b>. I'll message you about Arena wins, unclaimed winnings, auto-buys, quests, raffle prizes, predictions, duels, and when the gm streak is about to break.\nProfile: <a href="https://cavfi.com/u/${encodeURIComponent(label.endsWith('.cav') ? label : addr)}">cavfi.com/u/${esc(label.endsWith('.cav') ? label : short(addr))}</a>\n/me shows a summary, /unwatch stops.`);
}
async function watchSummary(chat){
  const mine = (state.watch || []).filter(w => w.chat === chat);
  if (!mine.length) return tgReply(chat, 'You follow no wallets yet. Try /watch kingdoge.cav or /watch 0x...');
  const lines = [];
  for (const w of mine){
    const bits = [];
    if (A.gm){ try{ const g = await new ethers.Contract(A.gm, ABI.gm, provider).info(w.addr); bits.push(`gm streak ${g.streak}${g.gmToday ? ' ✓ today' : ''}`); }catch(e){} }
    if (A.quests){ try{ const q = await new ethers.Contract(A.quests, ABI.qinfo, provider).info(w.addr); bits.push(`quest streak ${q.streak} · ${q.quests} quests`); }catch(e){} }
    lines.push(`• <b>${esc(w.label)}</b>${bits.length ? ': ' + bits.join(' · ') : ''}`);
  }
  await tgReply(chat, `👤 <b>Your wallets</b>\n${lines.join('\n')}`);
}
// gm streak at risk: once a day after GM_REMIND_HOUR_UTC, for followed wallets with a streak and no gm today
async function gmReminders(){
  if (!A.gm || !(state.watch || []).length) return;
  const t = now(), day = Math.floor(t / 86400);
  if ((t % 86400) / 3600 < CFG.gmRemindHour || state.gmRemindDay === day) return;
  state.gmRemindDay = day; saveState();
  const g = new ethers.Contract(A.gm, ABI.gm, provider), seen = new Set();
  for (const w of state.watch){
    if (seen.has(lk(w.addr))) continue; seen.add(lk(w.addr));
    try{
      const i = await g.info(w.addr);
      if (i.streak.gt(0) && !i.gmToday) await notifyUser(w.addr, `⏰ <b>Your ${i.streak}-day gm streak ends at midnight UTC.</b> Say gm on <a href="https://cavfi.com">cavfi.com</a> to keep it.`);
    }catch(e){}
  }
}

// ------------------------------------------------------------------ 10. CavFi Predict (DOGE price markets)
// The bot is the disclosed price oracle: it opens a daily and a weekly YES/NO market on the real DOGE/USD
// price, and after the resolve time reports the price of the 1-minute DOGEUSDT candle that opens at that
// moment on Binance (Coinbase DOGE-USD as a fallback). If nobody resolves a market within 7 days of its
// resolve time, anyone can turn it into a full refund on the contract.
async function getJson(url){
  const r = await fetch(url, {headers: {accept: 'application/json', 'user-agent': 'cavfi-bot'}});
  if (!r.ok) throw new Error(`${new URL(url).host} ${r.status}`);
  return r.json();
}
async function dogeNow(){
  if (CFG.predictPrice > 0) return CFG.predictPrice;
  try{ const j = await getJson('https://api.binance.com/api/v3/ticker/price?symbol=DOGEUSDT'); if (+j.price > 0) return +j.price; }catch(e){ log('binance price:', e.message); }
  const j = await getJson('https://api.exchange.coinbase.com/products/DOGE-USD/ticker');
  if (+j.price > 0) return +j.price;
  throw new Error('no DOGE price');
}
async function dogeAt(ts){
  if (CFG.predictPrice > 0) return CFG.predictPrice;
  try{
    const j = await getJson(`https://api.binance.com/api/v3/klines?symbol=DOGEUSDT&interval=1m&startTime=${ts * 1000}&limit=1`);
    if (j[0] && j[0][0] === ts * 1000 && +j[0][1] > 0) return +j[0][1];
  }catch(e){ log('binance candle:', e.message); }
  const iso = x => new Date(x * 1000).toISOString();
  const j = await getJson(`https://api.exchange.coinbase.com/products/DOGE-USD/candles?granularity=60&start=${iso(ts)}&end=${iso(ts + 60)}`);
  const c = (j || []).find(x => x[0] === ts);
  if (c && +c[3] > 0) return +c[3];
  throw new Error('no DOGE candle for ' + iso(ts));
}
const to8 = p => ethers.BigNumber.from(Math.round(p * 1e8));
const from8 = b => Number(b.toString()) / 1e8;
const sig3 = p => Number(p.toPrecision(3));
const usdP5 = p => '$' + (p >= 1 ? p.toFixed(4) : p.toPrecision(5));
const usdP = p => '$' + (p >= 1 ? p.toFixed(2) : p.toPrecision(3).replace(/0+$/, '').replace(/\.$/, ''));
const whenStr = ts => new Date(ts * 1000).toLocaleString('en-GB', {weekday: 'short', day: 'numeric', month: 'short', timeZone: 'UTC'}) + ', 20:00 UTC';
let predictAt = 0;
async function predictKeeper(){
  if (!CFG.predict || !A.predict || !wallet || me === ethers.constants.AddressZero || now() - predictAt < 60) return;
  predictAt = now();
  const c = new ethers.Contract(A.predict, ABI.predict, wallet);
  const [oracle, owner] = await Promise.all([c.oracle(), c.owner()]);
  if (lk(oracle) !== lk(me) && lk(owner) !== lk(me)){ log('predict: this wallet is not the oracle, skipping'); CFG.predict = false; return; }
  const t = (await provider.getBlock('latest')).timestamp;
  const [ids, items] = await c.page(0, 150);
  // 1. resolve markets whose time has come (wait a minute so the exchange candle exists)
  for (let i = 0; i < ids.length; i++){
    const m = items[i], id = ids[i].toNumber(), at = Number(m.resolveAt.toString());
    if (m.state !== 1 || t < at + 60 || t > at + 7 * 86400) continue;
    let price;
    try{ price = await dogeAt(at); }catch(e){ log(`predict #${id}: price not available yet (${e.message})`); continue; }
    const tx = await send(`predict #${id}: resolve at $${price}`, () => c.resolve(id, to8(price)));
    if (!tx) continue;
    const yes = to8(price).gt(m.strike), pot = fl(m.yesPool.add(m.noPool), 18);
    const refund = m.yesPool.isZero() || m.noPool.isZero(), hourly = m.question.startsWith('Hourly');
    if (pot > 0 && (!hourly || pot >= CFG.predictHourlyPostMin)) await tg(`🔮 <b>Predict #${id} resolved</b>\n${esc(m.question)}\nDOGE was <b>${hourly ? usdP5(price) : usdP(price)}</b> (line ${hourly ? usdP5(from8(m.strike)) : usdP(from8(m.strike))}): <b>${yes ? 'YES' : 'NO'}</b>.\n` +
      (refund ? `Only one side was backed, so everyone gets their ${fmtN(pot)} KingS back.` : `${fmtN(pot)} KingS pot goes to the ${yes ? 'YES' : 'NO'} side.`) +
      ` Claim on <a href="https://cavfi.com/#predict">cavfi.com/#predict</a>`);
    for (const w of [...new Set((state.watch || []).map(w => lk(w.addr)))]){
      try{
        const [y, n] = await Promise.all([c.yesOf(id, w), c.noOf(id, w)]);
        if (y.isZero() && n.isZero()) continue;
        const cl = fl(await c.claimable(id, w), 18);
        await notifyUser(w, `🔮 <b>Predict #${id}: ${yes ? 'YES' : 'NO'}</b> (DOGE ${usdP(price)})\n` +
          (cl > 0 ? `You can claim <b>${fmtN(cl)} KingS</b> on <a href="https://cavfi.com/#predict">cavfi.com/#predict</a>` : 'Your side lost this time.'));
      }catch(e){}
    }
  }
  // 2. open new markets: a daily one (20:00 UTC, at least 20 h away, closes 4 h before)
  //    and a weekly one (Sunday 20:00 UTC, line +5%, closes a day before)
  const want = [];
  const d20 = Math.floor(t / 86400) * 86400 + 20 * 3600;
  if (CFG.predictDaily){ let r = d20; while (r - t < 20 * 3600) r += 86400; want.push({resolveAt: r, closeAt: r - 4 * 3600, k: 1, kind: 'daily'}); }
  if (CFG.predictWeekly){
    let r = d20; while (new Date(r * 1000).getUTCDay() !== 0 || r - t < 36 * 3600) r += 86400;
    want.push({resolveAt: r, closeAt: r - 86400, k: 1.05, kind: 'weekly'});
  }
  const made = (state.predictMade ||= {});
  for (const w of want){
    const key = w.kind + ':' + w.resolveAt;
    if (made[key] || items.some(m => Number(m.resolveAt.toString()) === w.resolveAt && m.question.startsWith('Weekly') === (w.kind === 'weekly') && !m.question.startsWith('Hourly'))){ made[key] = 1; continue; }
    let p; try{ p = await dogeNow(); }catch(e){ log('predict: no DOGE price, not opening a market:', e.message); return; }
    const strike = sig3(p * w.k);
    const q = `${w.kind === 'weekly' ? 'Weekly: will' : 'Will'} DOGE be above ${usdP(strike)} on ${whenStr(w.resolveAt)}?`;
    const tx = await send(`predict: open ${w.kind} market`, () => c.create(q, to8(strike), w.closeAt, w.resolveAt));
    if (tx){ made[key] = 1; saveState(); }
    if (tx) await tg(`🔮 <b>New ${w.kind} prediction</b>\n${esc(q)}\nDOGE now ${usdP(p)}. Back YES or NO with KingS until ${new Date(w.closeAt * 1000).toISOString().slice(0, 16).replace('T', ' ')} UTC on <a href="https://cavfi.com/#predict">cavfi.com/#predict</a>\n<i>Testnet tokens. The CavFi bot reports the price from Binance.</i>`);
  }

  // 3. the hourly "up or down" market: opens a minute after each full hour, the line is DOGE's price at that
  //    hour (the open of Binance's 1-minute candle), it resolves an hour later and stops taking bets 10 minutes before.
  //    YES = DOGE is higher, NO = DOGE is the same or lower.
  if (CFG.predictHourly){
    const H = Math.floor(t / 3600) * 3600, r = H + 3600, key = 'hourly:' + r;
    if (!made[key] && t >= H + 60 && t < H + 20 * 60 && !items.some(m => Number(m.resolveAt.toString()) === r && m.question.startsWith('Hourly'))){
      let p = null; try{ p = await dogeAt(H); }catch(e){ log('predict: hourly line not available yet:', e.message); }
      if (p){
        const hh = x => new Date(x * 1000).toISOString().slice(11, 16);
        const q = `Hourly: will DOGE be above ${usdP5(p)} at ${hh(r)} UTC? (its price at ${hh(H)})`;
        const tx = await send('predict: open hourly market', () => c.create(q, to8(p), r - 600, r));
        if (tx){ made[key] = 1; saveState(); }
      }
    }
  }
  // forget keys older than 10 days
  for (const k of Object.keys(made)) if (Number(k.split(':')[1]) < t - 10 * 86400) delete made[k];
}

// ------------------------------------------------------------------ 11. Arena duels
// Matched duels are settled as soon as their Arena round is settled; open duels nobody accepted are sent
// back to their maker once Arena staking for that round has closed. Both are calls anyone could make.
let duelAt = 0;
async function duelKeeper(){
  if (!CFG.duels || !A.duel || !A.arena || !wallet || me === ethers.constants.AddressZero || now() - duelAt < 60) return;
  duelAt = now();
  const d = new ethers.Contract(A.duel, ABI.duel, wallet), ar = new ethers.Contract(A.arena, ABI.arena, provider);
  const [ids, items] = await d.page(0, 60);
  if (!ids.length) return;
  const cur = await ar.currentRound(), t = (await provider.getBlock('latest')).timestamp;
  const settled = {};
  for (let i = 0; i < ids.length; i++){
    const x = items[i], id = ids[i].toNumber(), rid = x.roundId.toNumber();
    if (x.state === 1 && (rid !== cur.id.toNumber() || t >= Number(cur.stakingEndsAt.toString()))){
      const tx = await send(`duel #${id}: nobody accepted, stake back to the maker`, () => d.cancel(id));
      if (tx) await notifyUser(x.maker, `⚔️ <b>Duel #${id}</b>: nobody accepted before Arena staking closed. Your ${fmtN(fl(x.stake, 18))} KingS are back in your wallet.`);
      continue;
    }
    if (x.state !== 2) continue;
    if (settled[rid] == null){ try{ settled[rid] = (await ar.getRound(rid)).settled; }catch(e){ settled[rid] = false; } }
    if (!settled[rid]) continue;
    const tx = await send(`duel #${id}: settle`, () => d.settle(id));
    if (!tx) continue;
    const rc = await provider.getTransactionReceipt(tx.hash);
    const ev = rc.logs.map(l => { try{ return d.interface.parseLog(l); }catch(e){ return null; } }).find(e => e && e.name === 'Settled');
    const [toks] = await ar.roundTokens(rid);
    const sa = (await token(toks[x.makerIdx])).symbol, sb = (await token(toks[x.takerIdx])).symbol;
    const [la, lb] = [await labelOf(x.maker), await labelOf(x.taker)], stake = fmtN(fl(x.stake, 18));
    if (ev && ev.args.winner !== ethers.constants.AddressZero){
      const makerWon = lk(ev.args.winner) === lk(x.maker);
      await tg(`⚔️ <b>Duel #${id}</b> (Arena round #${rid}): ${esc(makerWon ? sa : sb)} beat ${esc(makerWon ? sb : sa)}.\n<b>${esc(makerWon ? la : lb)}</b> wins ${fmtN(fl(ev.args.paid, 18))} KingS from ${esc(makerWon ? lb : la)}.`);
      await notifyUser(ev.args.winner, `⚔️ <b>You won duel #${id}!</b> ${esc(makerWon ? sa : sb)} beat ${esc(makerWon ? sb : sa)}: ${fmtN(fl(ev.args.paid, 18))} KingS are in your wallet.`);
      await notifyUser(makerWon ? x.taker : x.maker, `⚔️ <b>Duel #${id} lost</b>: ${esc(makerWon ? sa : sb)} beat ${esc(makerWon ? sb : sa)}. Your ${stake} KingS went to ${esc(makerWon ? la : lb)}.`);
    } else {
      await tg(`⚔️ <b>Duel #${id}</b> (round #${rid}): ${esc(sa)} vs ${esc(sb)} ended level, both players get their ${stake} KingS back.`);
      for (const u of [x.maker, x.taker]) await notifyUser(u, `⚔️ <b>Duel #${id}</b> ended level: your ${stake} KingS are back.`);
    }
  }
}

// ------------------------------------------------------------------ 12. Telegram link for the site
// The site's "Telegram alerts" button needs the bot's username: write it to tg.json next to the site.
async function setMiniApp(){
  if (!CFG.tgToken || state.miniAppSet === MINI_APP_URL) return;
  try{
    const r = await fetch(`${CFG.tgApi}/bot${CFG.tgToken}/setChatMenuButton`, {method: 'POST', headers: {'content-type': 'application/json'},
      body: JSON.stringify({menu_button: {type: 'web_app', text: 'Open CavFi', web_app: {url: MINI_APP_URL}}})}).then(x => x.json());
    if (r && r.ok){ state.miniAppSet = MINI_APP_URL; saveState(); log('telegram: menu button opens the CavFi mini app'); }
  }catch(e){ log('telegram setChatMenuButton failed:', e.message); }
}
async function writeTgJson(){
  if (!CFG.tgToken) return;
  try{
    const r = await fetch(`${CFG.tgApi}/bot${CFG.tgToken}/getMe`).then(x => x.json());
    const u = r && r.ok && r.result && r.result.username;
    if (!u) return;
    for (const dir of ['site', 'publish']){
      const f = path.join(HERE, '..', dir, 'tg.json');
      if (!fs.existsSync(path.dirname(f))) continue;
      const body = JSON.stringify({bot: u}) + '\n';
      if (!fs.existsSync(f) || fs.readFileSync(f, 'utf8') !== body){ fs.writeFileSync(f, body); log(`wrote ${dir}/tg.json (@${u})`); }
    }
  }catch(e){ log('telegram getMe failed:', e.message); }
}

// ------------------------------------------------------------------ 13. Telegram group: morning digest + commands
// Every morning (DIGEST_HOUR_UTC) the bot posts the day on CavFi to the group: today's quests, open DOGE
// markets with their odds, the Arena round, open duels and the raffle pot. Anyone can ask for each part:
// /quests /markets /arena /duels.
async function questsText(){
  if (!A.quests) return '';
  try{ const R = questRules(), day = Math.floor(now() / 86400), qs = R.questsFor(day, A);
    return `📜 <b>Today's quests</b> (1 raffle ticket each)\n${qs.map(q => `• ${esc(q.title)}`).join('\n')}`; }catch(e){ return ''; }
}
async function marketsText(){
  if (!A.predict) return '';
  try{
    const c = new ethers.Contract(A.predict, ABI.predict, provider), [ids, items] = await c.page(0, 20), t = now();
    const open = items.map((m, i) => ({m, id: ids[i].toNumber()})).filter(x => x.m.state === 1 && t < Number(x.m.closeAt.toString()));
    if (!open.length) return '🔮 <b>DOGE price markets</b>\nNo open market right now.';
    return `🔮 <b>DOGE price markets</b>\n` + open.map(({m, id}) => { const y = fl(m.yesPool, 18), n = fl(m.noPool, 18), tot = y + n;
      return `• ${esc(m.question.replace(/^(Weekly|Hourly): w/, 'W'))}\n   ${tot ? `YES ${Math.round(y / tot * 100)}% · NO ${Math.round(n / tot * 100)}% · ${fmtN(tot)} KingS` : 'nobody yet'} · <a href="https://cavfi.com/p/${id}">bet</a>`; }).join('\n');
  }catch(e){ return ''; }
}
async function arenaText(){
  if (!A.arena) return '';
  try{
    const c = new ethers.Contract(A.arena, ABI.arena, provider), r = await c.currentRound();
    if (!r.live) return '🏟️ <b>Arena</b>: the next round opens soon.';
    const [toks] = await c.roundTokens(r.id), syms = []; for (const a of toks) syms.push((await token(a)).symbol);
    const t = (await provider.getBlock('latest')).timestamp, left = Number(r.stakingEndsAt.toString()) - t;
    return `🏟️ <b>Arena round #${r.id}</b>: ${esc(syms.join(' · '))}\nPot ${r.pot.isZero() ? '0' : fmtN(fl(r.pot, 18))} KingS · ${left > 0 ? `staking open for ${Math.floor(left / 60)} min` : 'staking closed, result soon'} · <a href="https://cavfi.com/arena.html">play</a>`;
  }catch(e){ return ''; }
}
async function duelsText(){
  if (!A.duel || !A.arena) return '';
  try{
    const d = new ethers.Contract(A.duel, ABI.duel, provider), ar = new ethers.Contract(A.arena, ABI.arena, provider);
    const [ids, items] = await d.page(0, 30), r = await ar.currentRound();
    const open = items.map((x, i) => ({x, id: ids[i].toNumber()})).filter(o => o.x.state === 1 && o.x.roundId.eq(r.id) && o.x.invited === ethers.constants.AddressZero);
    if (!open.length) return '⚔️ <b>Duels</b>: none open. Start one: <a href="https://cavfi.com/#duels">cavfi.com/#duels</a>';
    const [toks] = await ar.roundTokens(r.id), sym = async i => (await token(toks[i])).symbol;
    const lines = [];
    for (const {x, id} of open.slice(0, 5)) lines.push(`• ${esc(await labelOf(x.maker))}: ${esc(await sym(x.makerIdx))} beats ${esc(await sym(x.takerIdx))} · ${fmtN(fl(x.stake, 18))} KingS · <a href="https://cavfi.com/duel/${id}">accept</a>`);
    return `⚔️ <b>Open duels</b>\n${lines.join('\n')}`;
  }catch(e){ return ''; }
}
async function raffleText(){
  if (!A.raffle) return '';
  try{ const r = await new ethers.Contract(A.raffle, ABI.raffle, provider).current();
    return `🎟️ <b>Royal Raffle</b> week #${r.id}: ${fmtN(fl(r.pot, 18))} KingS pot, ${r.totalTickets} tickets, draw ${new Date(Number(r.end.toString()) * 1000).toISOString().slice(0, 10)}`; }catch(e){ return ''; }
}
async function morningDigest(){
  if (!CFG.digest || !CFG.tgToken || !CFG.tgChat) return;
  const t = now(), day = Math.floor(t / 86400);
  if ((t % 86400) / 3600 < CFG.digestHour || state.digestDay === day) return;
  state.digestDay = day; saveState();
  const parts = (await Promise.all([questsText(), marketsText(), arenaText(), duelsText(), raffleText()])).filter(Boolean);
  await tg(`☀️ <b>gm CavFi!</b> Today on <a href="https://cavfi.com">cavfi.com</a>:\n\n${parts.join('\n\n')}\n\n<i>DogeOS testnet, tokens have no value.</i>`);
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
    // a lock not refreshed for 5 minutes is stale (after a crash or power cut Windows may give that pid to another program)
    const fresh = Date.now() - fs.statSync(LOCK).mtimeMs < 5 * 60000;
    if (pid && pid !== process.pid && fresh){ try{ process.kill(pid, 0); console.error(`Another CavFi bot is already running (pid ${pid}). Stop it first (stop-bot.ps1) or close its window.`); process.exit(3); }catch(e){ /* stale lock */ } }
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
  log(`predict: ${CFG.predict && A.predict ? 'on (bot is the DOGE price oracle)' : 'off'} · duels: ${CFG.duels && A.duel ? 'on' : 'off'} · followed wallets: ${(state.watch || []).length}`);
  await writeTgJson();
  await setMiniApp();
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
      await dcaKeeper();
      await questsDaily();
      await raffleKeeper();
      await predictKeeper();
      await duelKeeper();
      await alertsPoll();
      await gmReminders();
      await morningDigest();
      await weeklyTopTen();
      await heralds();
      await notify();
      errors = 0;
    }catch(e){
      errors++; log('round failed:', (e.reason || e.message || String(e)).slice(0, 160));
      if (errors === 5) await tg('⚠️ CavFi bot: 5 failed rounds in a row. Check the RPC or the bot wallet.');
    }
    if (CFG.once) break;
    try{ const t = new Date(); fs.utimesSync(LOCK, t, t); }catch(e){}   // keep the lock fresh
    await sleep(CFG.interval);
  }
}
main().catch(e => { console.error('Fatal:', e.message); process.exit(1); });
