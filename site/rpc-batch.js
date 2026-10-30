/* CavFi: one shared, frugal connection to the DogeOS RPC (ethers v5).
 *
 * The pages read a lot of small things (balances, rounds, names…). Sent one by one that is 100+ HTTP
 * requests per page and the public RPC answers 429 (too many requests). This provider:
 *  - packs every plain read (eth_call at 'latest') made in the same ~12 ms into one Multicall3 call;
 *  - sends everything else in JSON-RPC batches (one HTTP request for many calls);
 *  - caches reads for a few seconds (logs over a fixed block range and old blocks for an hour);
 *  - retries with back-off when the RPC answers 429 or the network drops.
 * A read that fails inside a multicall is re-sent on its own, so revert reasons look exactly as before.
 * Usage: CavRpc.make(ethers, url, chainId) - one instance per URL, shared by every script on the page.
 */
(function (root) {
  'use strict';
  const MC = '0xcA11bde05977b3631167028862bE2a173976CA11';   // Multicall3, same address on every chain (deployed on DogeOS)
  const instances = {};

  function make(E, url, chainId, opts) {
    opts = opts || {};
    const k = url + '|' + chainId;
    if (instances[k]) return instances[k];
    const mcI = new E.utils.Interface(['function aggregate3((address target, bool allowFailure, bytes callData)[] calls) payable returns ((bool success, bytes returnData)[] returnData)']);
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const isNum = t => typeof t === 'string' && /^0x[0-9a-f]+$/i.test(t);

    class CavProvider extends E.providers.StaticJsonRpcProvider {
      constructor() {
        super(url, chainId);
        this._cavQ = []; this._cavMQ = []; this._cavT = null; this._cavId = 1;
        this._cavCache = new Map();
        this.rpcStats = {http: 0, calls: 0, multicalled: 0, cached: 0, retries: 0};
        this.multicall = opts.multicall !== false;
      }
      clearCache() { this._cavCache.clear(); }
      _cavTtl(method, params) {
        if (method === 'eth_blockNumber') return 2000;
        if (method === 'eth_getCode') return 600000;
        if (method === 'eth_getLogs') { const f = params[0] || {}; return isNum(f.fromBlock) && isNum(f.toBlock) ? 3600000 : 4000; }
        if (method === 'eth_getBlockByNumber') return isNum(params[0]) ? 3600000 : 2000;
        if (method === 'eth_call' || method === 'eth_getBalance') return 4000;
        return 0;
      }
      send(method, params) {
        params = params || [];
        if (method === 'eth_chainId') return Promise.resolve(E.utils.hexValue(chainId));
        if (method === 'net_version') return Promise.resolve(String(chainId));
        const ttl = this._cavTtl(method, params), key = ttl ? method + JSON.stringify(params) : null;
        if (key) {
          const c = this._cavCache.get(key);
          if (c && Date.now() - c.t < ttl) { this.rpcStats.cached++; return c.p; }
        }
        let p;
        const tx = params[0] || {};
        if (method === 'eth_call' && this.multicall && (params[1] === 'latest' || params[1] == null) && !tx.from && !tx.value && tx.to && tx.data && tx.to.toLowerCase() !== MC.toLowerCase())
          p = new Promise((res, rej) => { this._cavMQ.push({tx, params, res, rej}); this._cavSched(); });
        else p = this._cavEnqueue(method, params);
        if (key) {
          if (this._cavCache.size > 3000) this._cavCache.clear();
          this._cavCache.set(key, {t: Date.now(), p});
          p.catch(() => { const c = this._cavCache.get(key); if (c && c.p === p) this._cavCache.delete(key); });
        }
        return p;
      }
      _cavEnqueue(method, params) {
        return new Promise((res, rej) => { this._cavQ.push({method, params, res, rej}); this._cavSched(); });
      }
      _cavSched() { if (!this._cavT) this._cavT = setTimeout(() => { this._cavT = null; this._cavFlush(); }, 12); }
      _cavFlush() {
        const mq = this._cavMQ.splice(0);
        for (let i = 0; i < mq.length; i += 40) {
          const part = mq.slice(i, i + 40);
          if (part.length === 1) { const m = part[0]; this._cavEnqueue('eth_call', m.params).then(m.res, m.rej); continue; }
          this.rpcStats.multicalled += part.length;
          const data = mcI.encodeFunctionData('aggregate3', [part.map(m => ({target: m.tx.to, allowFailure: true, callData: m.tx.data}))]);
          this._cavEnqueue('eth_call', [{to: MC, data}, 'latest']).then(out => {
            const [rows] = mcI.decodeFunctionResult('aggregate3', out);
            part.forEach((m, j) => {
              const r = rows[j];
              // a failed read goes again on its own, so ethers sees the real revert
              if (r && r.success && (r.returnData !== '0x' || m.retryEmptyDone)) m.res(r.returnData);
              else this._cavEnqueue('eth_call', m.params).then(m.res, m.rej);
            });
          }, () => part.forEach(m => this._cavEnqueue('eth_call', m.params).then(m.res, m.rej)));
        }
        const q = this._cavQ.splice(0);
        for (let i = 0; i < q.length; i += 40) this._cavPost(q.slice(i, i + 40));
      }
      async _cavPost(items) {
        const body = items.map(it => ({jsonrpc: '2.0', id: this._cavId++, method: it.method, params: it.params}));
        this.rpcStats.calls += items.length;
        for (let n = 0; ; n++) {
          try {
            this.rpcStats.http++;
            const r = await fetch(url, {method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify(body)});
            if ((r.status === 429 || r.status >= 500) && n < 5) { this.rpcStats.retries++; await sleep(400 * 2 ** n + Math.random() * 300); continue; }
            const j = await r.json();
            if (!Array.isArray(j)) {
              if (j && j.error && /rate|limit|too many/i.test(j.error.message || '') && n < 5) { this.rpcStats.retries++; await sleep(400 * 2 ** n + Math.random() * 300); continue; }
              // the endpoint refused the batch: send the calls one by one
              if (items.length > 1) { for (const it of items) this._cavPost([it]); return; }
              throw Object.assign(new Error((j && j.error && j.error.message) || 'bad RPC response'), j && j.error ? {code: j.error.code, data: j.error.data} : {});
            }
            const byId = {}; j.forEach(x => byId[x.id] = x);
            items.forEach((it, k) => {
              const x = byId[body[k].id];
              if (!x) return it.rej(new Error('missing RPC response'));
              if (x.error) { const e = new Error(x.error.message); e.code = x.error.code; e.data = x.error.data; return it.rej(e); }
              it.res(x.result);
            });
            return;
          } catch (e) {
            if (n < 4 && !(e && e.code)) { this.rpcStats.retries++; await sleep(400 * 2 ** n); continue; }
            items.forEach(it => it.rej(e));
            return;
          }
        }
      }
    }
    return (instances[k] = new CavProvider());
  }
  root.CavRpc = {make, MULTICALL3: MC};
})(typeof self !== 'undefined' ? self : this);
