/* CavFi Arena: latest rounds and their winners.
   Self-mounting: fills every element with a data-arena-winners attribute (data-limit = rows, default 6).
   Reads addresses.json and the chain directly (ethers 5 UMD must be on the page). Settled rounds never
   change, so each one is cached in localStorage after the first read. */
(function(){
  'use strict';
  var RPC_DEFAULT = 'https://rpc.testnet.dogeos.com';
  var ARENA_ABI = [
    'function lastSettled() view returns (uint256)',
    'function currentRound() view returns (uint256 id, uint64 start, uint64 end, uint64 stakingEndsAt, uint256 secondsLeft, uint256 pot, uint16 feeBps, bool live)',
    'function getRound(uint256 id) view returns (tuple(uint64 start, uint64 end, uint16 feeBps, uint8 winnerMask, bool settled, uint256 staked, uint256 rollover, uint256 winnerStake, uint256 payout))',
    'function roundTokens(uint256 id) view returns (address[] tokens, address[] pairs)',
    'event Staked(uint256 indexed id, address indexed user, uint256 indexed idx, uint256 amount)'
  ];
  var ERC20_ABI = ['function symbol() view returns (string)'];
  var NAMES_ABI = ['function namesOf(address[]) view returns (string[])'];
  var CACHE = 'cavfi.arenaWinners.v1';

  function css(){
    if (document.getElementById('awStyle')) return;
    var s = document.createElement('style'); s.id = 'awStyle';
    s.textContent =
      '.aw-head{display:flex;align-items:baseline;justify-content:space-between;gap:12px;margin-bottom:6px}' +
      '.aw-head h2{margin:0}.aw-head a{font-size:13px;font-weight:600;color:var(--chestnut,#A3461E);text-decoration:none}' +
      '.aw-row{display:grid;grid-template-columns:auto minmax(0,1fr) auto;gap:12px;align-items:center;padding:10px 2px;border-top:1px solid var(--line,#DADBE5)}' +
      '.aw-id{font:600 12px var(--mono,ui-monospace,monospace);color:var(--muted,#686780);min-width:34px}' +
      '.aw-main{min-width:0}.aw-main b{display:block;font-size:14.5px}' +
      '.aw-main small{display:block;color:var(--muted,#686780);font-size:12.5px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}' +
      '.aw-v{text-align:right;font:600 13.5px var(--mono,ui-monospace,monospace);white-space:nowrap}' +
      '.aw-v small{display:block;font:500 11.5px var(--body,system-ui);color:var(--muted,#686780)}' +
      '.aw-tag{display:inline-block;margin-left:6px;padding:1px 7px;border-radius:999px;font:600 11px var(--body,system-ui);vertical-align:1px}' +
      '.aw-tag.win{background:var(--ok,#1F7A4D);color:#fff}.aw-tag.roll{background:var(--line,#DADBE5);color:var(--ink,#1B1A2E)}' +
      '.aw-empty{color:var(--muted,#686780);font-size:14px;padding:8px 2px}';
    document.head.appendChild(s);
  }
  var esc = function(s){ return String(s).replace(/[&<>"']/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); };
  var short = function(a){ return a.slice(0, 6) + '…' + a.slice(-4); };
  var fmt = function(n){ return n >= 1000 ? Math.round(n).toLocaleString('en-US') : n.toLocaleString('en-US', {maximumFractionDigits: 2}); };
  function loadCache(){ try{ return JSON.parse(localStorage.getItem(CACHE) || '{}') || {}; }catch(e){ return {}; } }
  function saveCache(c){ try{ localStorage.setItem(CACHE, JSON.stringify(c)); }catch(e){} }

  var ctx = null;
  async function setup(){
    if (ctx) return ctx;
    var E = window.ethers; if (!E) throw new Error('ethers missing');
    var a = {};
    try{ var r = await fetch('addresses.json', {cache: 'no-store'}); if (r.ok) a = await r.json(); }catch(e){}
    if (!a.arena) return ctx = {off: true};
    var p = new E.providers.StaticJsonRpcProvider(a.rpc || RPC_DEFAULT, a.chainId || 6281971);
    return ctx = {E: E, a: a, p: p, c: new E.Contract(a.arena, ARENA_ABI, p), syms: {}, blocks: {}};
  }
  async function sym(addr){
    var k = addr.toLowerCase(), x = ctx.a;
    if (ctx.syms[k]) return ctx.syms[k];
    if (x.usdt && k === x.usdt.toLowerCase()) return ctx.syms[k] = 'cUSDT';
    if (x.usdc && k === x.usdc.toLowerCase()) return ctx.syms[k] = 'cUSDC';
    try{ return ctx.syms[k] = await new ctx.E.Contract(addr, ERC20_ABI, ctx.p).symbol(); }catch(e){ return ctx.syms[k] = short(addr); }
  }
  async function blockTs(b){ if (ctx.blocks[b] == null) ctx.blocks[b] = (await ctx.p.getBlock(b)).timestamp; return ctx.blocks[b]; }
  async function blockAt(ts, hi){
    var lo = Math.max(1, hi - 400000);
    if (await blockTs(lo) > ts) return lo;
    while (hi - lo > 1){ var mid = Math.floor((lo + hi) / 2); if (await blockTs(mid) < ts) lo = mid; else hi = mid; }
    return lo;
  }
  // One settled round: winning symbols, and per winning wallet its share of the payout.
  async function readRound(id, head){
    var E = ctx.E, c = ctx.c, r = await c.getRound(id);
    var toks = (await c.roundTokens(id)).tokens, wins = [];
    for (var i = 0; i < toks.length; i++) if ((r.winnerMask >> i) & 1) wins.push(await sym(toks[i]));
    var out = {id: id, wins: wins, staked: +E.utils.formatEther(r.staked), rollover: +E.utils.formatEther(r.rollover),
      payout: +E.utils.formatEther(r.payout), rolled: r.winnerStake.isZero(), winners: []};
    if (out.rolled) return out;
    var from = await blockAt(Number(r.start.toString()) - 60, head), end = await blockAt(Number(r.end.toString()) + 3600, head);
    var topic = c.interface.getEventTopic('Staked'), idT = E.utils.hexZeroPad(E.BigNumber.from(id).toHexString(), 32), per = {};
    for (var b = from; b <= end; b += 9999){
      var logs = await ctx.p.getLogs({address: ctx.a.arena, fromBlock: b, toBlock: Math.min(end, b + 9998), topics: [topic, idT]});
      for (var j = 0; j < logs.length; j++){
        var ev = c.interface.parseLog(logs[j]), idx = ev.args.idx.toNumber();
        if (!((r.winnerMask >> idx) & 1)) continue;
        var u = E.utils.getAddress(ev.args.user);
        per[u] = (per[u] || E.constants.Zero).add(ev.args.amount);
      }
    }
    var users = Object.keys(per), names = users.map(function(){ return ''; });
    if (ctx.a.names && users.length){ try{ names = await new E.Contract(ctx.a.names, NAMES_ABI, ctx.p).namesOf(users); }catch(e){} }
    out.winners = users.map(function(u, k){
      var amt = +E.utils.formatEther(per[u].mul(r.payout).div(r.winnerStake));
      return {user: u, name: /^[a-z0-9-]{3,32}$/.test(names[k] || '') ? names[k] + '.cav' : '', amount: amt};
    }).sort(function(x, y){ return y.amount - x.amount; });
    return out;
  }
  async function rounds(limit){
    await setup(); if (ctx.off) return null;
    var last = (await ctx.c.lastSettled()).toNumber(); if (!last) return [];
    var head = await ctx.p.getBlockNumber(), cache = loadCache(), key = ctx.a.arena.toLowerCase(), mine = cache[key] || (cache[key] = {});
    var list = [];
    // rounds where somebody played: a win, or bets that lost to a token nobody backed.
    // Rounds without a single bet are skipped; at most the last 72 rounds are scanned.
    for (var id = last; id >= 1 && id > last - 72 && list.length < limit; id--){
      var x = mine[id];
      if (!x){ x = await readRound(id, head); mine[id] = x; saveCache(cache); }
      if (!x.rolled || x.staked > 0) list.push(x);
    }
    return list;
  }
  function row(x){
    var who, val, tag;
    if (!x.rolled){
      var w = x.winners;
      who = w.length ? (w.length === 1 ? esc(w[0].name || short(w[0].user)) + ' took the pot'
        : esc(w[0].name || short(w[0].user)) + ' + ' + (w.length - 1) + ' more shared the pot') : 'Winners shared the pot';
      val = fmt(x.payout) + ' KingS<small>paid out</small>'; tag = '<span class="aw-tag win">won</span>';
    } else {
      who = 'Nobody backed the winner'; val = fmt(x.staked + x.rollover) + ' KingS<small>rolled over</small>'; tag = '<span class="aw-tag roll">rolled</span>';
    }
    var top = x.wins.length ? esc(x.wins.join(' + ')) + ' rose most' : 'No winner';
    return '<div class="aw-row"><span class="aw-id">#' + x.id + '</span><span class="aw-main"><b>' + top + tag + '</b><small>' + who + '</small></span><span class="aw-v">' + val + '</span></div>';
  }
  async function mount(el){
    css();
    var limit = parseInt(el.getAttribute('data-limit') || '6', 10) || 6, link = el.getAttribute('data-link');
    var head = '<div class="aw-head card-head sx-head"><h2>Latest Arena rounds</h2>' + (link ? '<a href="' + esc(link) + '">Play the Arena →</a>' : '') + '</div>';
    if (!el.innerHTML.trim()) el.innerHTML = head + '<div class="aw-empty">Reading the last rounds…</div>';
    try{
      var list = await rounds(limit);
      if (list === null){ el.hidden = true; return; }
      el.hidden = false;
      el.innerHTML = head + (list.length ? list.map(row).join('') : '<div class="aw-empty">No bets in the last rounds yet. Be the first.</div>');
    }catch(e){ el.innerHTML = head + '<div class="aw-empty">Could not read the Arena right now.</div>'; }
  }
  function mountAll(){ document.querySelectorAll('[data-arena-winners]').forEach(mount); }
  window.CavWinners = {refresh: mountAll};
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mountAll); else mountAll();
  setInterval(function(){ if (!document.hidden) mountAll(); }, 120000);
})();
