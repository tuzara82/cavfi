/* CavFi Arena: live race chart.
   Self-mounting: fills every element with a data-arena-race attribute. Shows how each token of the current
   round moved against DOGE since the round's start price, from the start of the round until now, and keeps
   ticking every 10 seconds. The history comes from the pools' own Sync events, scaled to the Arena's own
   price units, so the last point always matches what the Arena contract sees. Needs ethers 5 UMD on the page. */
(function(){
  'use strict';
  var RPC_DEFAULT = 'https://rpc.testnet.dogeos.com', CHAIN = 6281971, TICK = 10000, BT = 3;
  var ARENA_ABI = [
    'function currentRound() view returns (uint256 id, uint64 start, uint64 end, uint64 stakingEndsAt, uint256 secondsLeft, uint256 pot, uint16 feeBps, bool live)',
    'function roundTokens(uint256 id) view returns (address[] tokens, address[] pairs)',
    'function board(uint256 id) view returns (uint256[] pots, uint256[] startAvg, uint256[] endAvg, uint32[] startCnt, uint32[] endCnt)',
    'function spotPrices(uint256 id) view returns (uint256[] prices)'
  ];
  var PAIR_ABI = ['function token0() view returns (address)', 'function getReserves() view returns (uint112, uint112, uint32)'];
  var ERC20_ABI = ['function symbol() view returns (string)'];
  var SYNC = '0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1';
  var COLORS = ['#D46A38', '#1F9E6E', '#E7B73C', '#4C7DF0', '#9C5BD6', '#E0567A', '#20A8C2', '#8A7F22'];
  var esc = function(s){ return String(s).replace(/[&<>"']/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); };

  function css(){
    if (document.getElementById('arRaceStyle')) return;
    var s = document.createElement('style'); s.id = 'arRaceStyle';
    s.textContent =
      '.rc-head{display:flex;align-items:baseline;justify-content:space-between;gap:12px;flex-wrap:wrap;margin-bottom:8px}.rc-head h2{margin:0}' +
      '.rc-head small{color:var(--muted,#686780);font-size:12.5px}' +
      '.rc-svg{width:100%;height:auto;display:block;overflow:visible}' +
      '.rc-svg text{font:600 12px var(--mono,ui-monospace,monospace)}' +
      '.rc-legend{display:flex;flex-wrap:wrap;gap:8px 14px;margin-top:8px}' +
      '.rc-legend span{display:inline-flex;align-items:center;gap:6px;font:600 13.5px var(--body,system-ui)}' +
      '.rc-legend i{width:12px;height:12px;border-radius:4px;display:inline-block}' +
      '.rc-legend b{font:600 13px var(--mono,ui-monospace,monospace)}.rc-legend .lead b{color:var(--gold,#C9961A)}' +
      '.rc-empty{color:var(--muted,#686780);font-size:14px;padding:10px 2px}' +
      '@keyframes rcPulse{0%,100%{r:5}50%{r:8}}.rc-dot{animation:rcPulse 1.6s ease-in-out infinite}';
    document.head.appendChild(s);
  }

  var S = {round: null, toks: [], pairs: [], scale: [], side: [], hist: [], base: null, fetched: false};

  function priceFromReserves(r0, r1, dogeIs0){   // DOGE per token (raw ratio, scaled later)
    var a = Number(r0.toString ? r0.toString() : r0), b = Number(r1.toString ? r1.toString() : r1);
    return dogeIs0 ? (b ? a / b : 0) : (a ? b / a : 0);
  }

  async function setupRound(arena, rp, A, r){
    S.round = r.id.toString(); S.hist = []; S.toks = []; S.base = null;
    var rt = await arena.roundTokens(r.id);
    S.pairs = rt.pairs;
    S.toks = await Promise.all(rt.tokens.map(function(a){ return new ethers.Contract(a, ERC20_ABI, rp).symbol().catch(function(){ return a.slice(0, 6); }); }));
    var t0s = await Promise.all(rt.pairs.map(function(p){ return new ethers.Contract(p, PAIR_ABI, rp).token0(); }));
    S.side = t0s.map(function(t){ return t.toLowerCase() === String(A.wdoge || '').toLowerCase(); });
    // scale = Arena spot price / our reserve ratio, so the history uses the Arena's units
    var spots = await arena.spotPrices(r.id);
    var res = await Promise.all(rt.pairs.map(function(p){ return new ethers.Contract(p, PAIR_ABI, rp).getReserves(); }));
    S.scale = res.map(function(x, i){ var p = priceFromReserves(x[0], x[1], S.side[i]); return p ? Number(ethers.utils.formatUnits(spots[i], 18)) / p : 1; });
    // backfill from the round start: the pools' reserves at the start block, then every Sync event since
    var head = await rp.getBlock('latest'), start = r.start.toNumber();
    // the last block at or before the round start (binary search on block time)
    var lo = Math.max(0, head.number - Math.ceil((head.timestamp - start) / BT) * 3), hi = head.number;
    while (lo < hi){ var mid = Math.ceil((lo + hi) / 2), mb = await rp.getBlock(mid); if (mb && mb.timestamp <= start) lo = mid; else hi = mid - 1; }
    var fromB = lo;
    var startRes = await Promise.all(rt.pairs.map(function(p){ return new ethers.Contract(p, PAIR_ABI, rp).getReserves({blockTag: fromB}).catch(function(){ return null; }); }));
    var logs = [];
    for (var b = fromB + 1; b <= head.number; b += 9000){
      var to = Math.min(head.number, b + 8999);
      logs = logs.concat(await rp.send('eth_getLogs', [{address: rt.pairs, fromBlock: ethers.utils.hexValue(b), toBlock: ethers.utils.hexValue(to), topics: [SYNC]}]));
    }
    logs.sort(function(x, y){ return parseInt(x.blockNumber, 16) - parseInt(y.blockNumber, 16) || parseInt(x.logIndex, 16) - parseInt(y.logIndex, 16); });
    var lowerPairs = rt.pairs.map(function(p){ return p.toLowerCase(); });
    var touched = {}; logs.forEach(function(l){ touched[lowerPairs.indexOf(l.address.toLowerCase())] = true; });
    // a pool with no trade since the start still has today's reserves
    var state = res.map(function(x, i){ var sr = startRes[i]; return sr ? priceFromReserves(sr[0], sr[1], S.side[i]) : (touched[i] ? null : priceFromReserves(x[0], x[1], S.side[i])); });
    var points = [{t: start, p: state.slice()}];
    var bnums = Array.from(new Set(logs.map(function(l){ return parseInt(l.blockNumber, 16); }))).slice(-200), bts = {};
    await Promise.all(bnums.map(function(n){ return rp.getBlock(n).then(function(b){ bts[n] = b.timestamp; }).catch(function(){}); }));
    logs.forEach(function(l){
      var i = lowerPairs.indexOf(l.address.toLowerCase()); if (i < 0) return;
      var n = parseInt(l.blockNumber, 16);
      state[i] = priceFromReserves(BigInt('0x' + l.data.slice(2, 66)), BigInt('0x' + l.data.slice(66, 130)), S.side[i]);
      points.push({t: bts[n] || head.timestamp - (head.number - n) * BT, p: state.slice()});
    });
    S.hist = points;
    S.fetched = true;
  }

  async function tick(host, arena, rp, A){
    var r = await arena.currentRound();
    if (!r.live || r.id.isZero()){ host.innerHTML = '<div class="rc-head"><h2>Live race</h2></div><div class="rc-empty">No round is live right now. The race starts with the next round.</div>'; return; }
    if (S.round !== r.id.toString()) await setupRound(arena, rp, A, r);
    var bd = await arena.board(r.id), spots = await arena.spotPrices(r.id);
    var now = (await rp.getBlock('latest')).timestamp;   // chain time, the same clock as the round
    var spotN = spots.map(function(x){ return Number(ethers.utils.formatUnits(x, 18)); });
    S.hist.push({t: Math.min(now, r.end.toNumber()), p: spotN.map(function(v, i){ return S.scale[i] ? v / S.scale[i] : v; })});
    // baseline: the Arena's start average once it exists, else the first known price of the round
    var startN = bd.startAvg.map(function(x){ return Number(ethers.utils.formatUnits(x, 18)); });
    var haveStart = bd.startCnt.every(function(c){ return c > 0; }) && startN.every(function(x){ return x > 0; });
    var base = S.toks.map(function(_, i){
      if (haveStart) return startN[i] / (S.scale[i] || 1);
      for (var k = 0; k < S.hist.length; k++) if (S.hist[k].p[i]) return S.hist[k].p[i];
      return null;
    });
    render(host, r, base, haveStart);
  }

  function render(host, r, base, haveStart){
    var W = 800, H = 280, L = 8, R = 120, T = 14, B = 26;
    var t0 = r.start.toNumber(), t1 = r.end.toNumber();
    var series = S.toks.map(function(_, i){
      var pts = []; var lastP = null;
      S.hist.forEach(function(h){ var p = h.p[i] != null ? h.p[i] : lastP; if (p != null && base[i]){ lastP = p; pts.push([h.t, (p / base[i] - 1) * 100]); } });
      return pts;
    });
    var all = [0]; series.forEach(function(s){ s.forEach(function(p){ all.push(p[1]); }); });
    var lo = Math.min.apply(null, all), hi = Math.max.apply(null, all), pad = Math.max(0.2, (hi - lo) * 0.15);
    lo -= pad; hi += pad;
    var x = function(t){ return L + (W - L - R) * Math.max(0, Math.min(1, (t - t0) / (t1 - t0))); };
    var y = function(v){ return T + (H - T - B) * (1 - (v - lo) / (hi - lo)); };
    var last = series.map(function(s){ return s.length ? s[s.length - 1][1] : null; });
    var valid = last.filter(function(v){ return v != null; });
    var best = Math.max.apply(null, valid.concat([-Infinity]));
    var tied = valid.length && valid.every(function(v){ return Math.abs(v - valid[0]) < 0.0005; });
    var lines = series.map(function(s, i){
      if (!s.length) return '';
      var d = s.map(function(p, k){ return k ? 'H' + x(p[0]).toFixed(1) + ' V' + y(p[1]).toFixed(1) : 'M' + x(p[0]).toFixed(1) + ' ' + y(p[1]).toFixed(1); }).join(' ');   // prices move in steps
      var e = s[s.length - 1], lead = !tied && Math.abs(e[1] - best) < 0.0005;
      return '<path d="' + d + '" fill="none" stroke="' + COLORS[i % COLORS.length] + '" stroke-width="' + (lead ? 3.2 : 2.2) + '" stroke-linejoin="round" stroke-linecap="round"/>' +
        '<circle class="rc-dot" cx="' + x(e[0]).toFixed(1) + '" cy="' + y(e[1]).toFixed(1) + '" r="5" fill="' + COLORS[i % COLORS.length] + '"/>' +
        '<text x="' + (x(e[0]) + 10).toFixed(1) + '" y="' + (y(e[1]) + 4).toFixed(1) + '" fill="' + COLORS[i % COLORS.length] + '">' + (lead ? '👑 ' : '') + esc(S.toks[i]) + ' ' + (e[1] >= 0 ? '+' : '') + e[1].toFixed(2) + '%</text>';
    }).join('');
    var sw = x(r.start.toNumber() + 600), ew = x(r.end.toNumber() - 600);
    var svg = '<svg class="rc-svg" viewBox="0 0 ' + W + ' ' + H + '" role="img" aria-label="Token prices against DOGE during this round">' +
      '<rect x="' + L + '" y="' + T + '" width="' + (sw - L) + '" height="' + (H - T - B) + '" fill="currentColor" opacity=".05"/>' +
      '<rect x="' + ew + '" y="' + T + '" width="' + (W - R - ew) + '" height="' + (H - T - B) + '" fill="currentColor" opacity=".05"/>' +
      '<line x1="' + L + '" x2="' + (W - R) + '" y1="' + y(0) + '" y2="' + y(0) + '" stroke="currentColor" opacity=".35" stroke-dasharray="4 4"/>' +
      '<text x="' + (W - R + 6) + '" y="' + (y(0) + 4) + '" fill="currentColor" opacity=".6">DOGE</text>' +
      '<text x="' + (L + 4) + '" y="' + (H - 8) + '" fill="currentColor" opacity=".55">start price window</text>' +
      '<text x="' + (ew + 4) + '" y="' + (H - 8) + '" fill="currentColor" opacity=".55">end window</text>' +
      lines + '</svg>';
    var legend = S.toks.map(function(sym, i){ var v = last[i], lead = !tied && v != null && Math.abs(v - best) < 0.0005;
      return '<span class="' + (lead ? 'lead' : '') + '"><i style="background:' + COLORS[i % COLORS.length] + '"></i>' + esc(sym) + ' <b>' + (v == null ? '—' : (v >= 0 ? '+' : '') + v.toFixed(2) + '%') + '</b>' + (lead ? ' 👑' : '') + '</span>'; }).join('');
    host.innerHTML = '<div class="rc-head"><h2>Live race · round #' + esc(r.id.toString()) + '</h2><small>' +
      (haveStart ? 'change against DOGE since the start price · updates every 10 s' : 'start prices are still being recorded: shown against the first price of the round') + '</small></div>' + svg + '<div class="rc-legend">' + legend + '</div>';
  }

  async function mount(){
    var hosts = document.querySelectorAll('[data-arena-race]'); if (!hosts.length || !window.ethers) return;
    css();
    var A = {}; try{ A = await fetch('addresses.json', {cache: 'no-store'}).then(function(r){ return r.json(); }); }catch(e){}
    if (!A.arena) return;
    var rp = new ethers.providers.StaticJsonRpcProvider(A.rpc || RPC_DEFAULT, CHAIN);
    var arena = new ethers.Contract(A.arena, ARENA_ABI, rp);
    var host = hosts[0];
    host.innerHTML = '<div class="rc-head"><h2>Live race</h2></div><div class="rc-empty">Loading the round…</div>';
    var run = async function(){ if (document.hidden) return; try{ await tick(host, arena, rp, A); }catch(e){ console.warn('arena race', e); } };
    await run(); setInterval(run, TICK);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mount); else mount();
})();
