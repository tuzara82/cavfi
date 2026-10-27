/* CavFi: RedStone price payloads (pull model)
 *
 * The CavFi Predict and Guess contracts decide markets with the DOGE/USD price signed by RedStone's
 * primary-prod oracle nodes at the exact decision moment (for example 20:00:00 UTC). Anyone can fetch
 * those signed data packages from RedStone's public gateways and append them to the transaction; the
 * contract checks the signatures (3 of RedStone's 5 primary-prod signers) and the timestamp itself.
 *
 * Works in the browser (window.CavRedstone) and in Node (require / createRequire).
 * Payload layout: https://github.com/redstone-finance/redstone-oracles-monorepo/tree/main/packages/evm-connector
 */
(function (root) {
  'use strict';
  const GATEWAYS = [
    'https://oracle-gateway-2.a.redstone.finance',
    'https://oracle-gateway-1.a.redstone.finance',
  ];
  const SERVICE = 'redstone-primary-prod';
  const SIGNERS = [   // redstone-primary-prod, the same list the contracts accept
    '0x8bb8f32df04c8b654987daaed53d6b6091e3b774',
    '0xdeb22f54738d54976c4c0fe5ce6d408e40d88499',
    '0x51ce04be4b3e32572c4ec9135221d0691ba7d202',
    '0xdd682daec5a90dd295d14da4b0bec9281017b5be',
    '0x9c5ae89c4af6aa32ce58588dbaf90d18a855b6de',
  ];
  const MARKER = '000002ed57011e0000';
  const NEED = 3;

  const hexN = (n, bytes) => BigInt(n).toString(16).padStart(bytes * 2, '0');
  const b64hex = s => {
    let bin;
    if (typeof atob === 'function') bin = atob(s);
    else bin = Buffer.from(s, 'base64').toString('binary');
    let h = ''; for (let i = 0; i < bin.length; i++) h += bin.charCodeAt(i).toString(16).padStart(2, '0');
    return h;
  };
  const feedHex = id => { let h = ''; for (const c of id) h += c.charCodeAt(0).toString(16).padStart(2, '0'); return h.padEnd(64, '0'); };
  // RedStone numbers have 8 decimals on chain
  const units = v => {
    const s = typeof v === 'string' ? v : Number(v).toFixed(8);
    const [i, f = ''] = s.split('.');
    return BigInt(i || '0') * 100000000n + BigInt((f + '00000000').slice(0, 8));
  };

  /** Signed packages for `feed` at exactly `tsSec` (unix seconds, a multiple of 10). Returns [] if not available. */
  async function fetchPackages(tsSec, feed, opts) {
    feed = feed || 'DOGE'; opts = opts || {};
    const doFetch = opts.fetch || (typeof fetch === 'function' ? fetch : null);
    const gws = opts.gateways || GATEWAYS;
    const ms = Number(tsSec) * 1000;
    let lastErr = null;
    for (const g of gws) {
      try {
        const r = await doFetch(`${g}/data-packages/historical/${SERVICE}/${ms}`);
        if (!r.ok) { lastErr = new Error(`${g}: HTTP ${r.status}`); continue; }
        const txt = await r.text();
        if (txt[0] !== '{') { lastErr = new Error(`${g}: no data`); continue; }
        const j = JSON.parse(txt), list = (j[feed] || []).filter(p => Number(p.timestampMilliseconds) === ms
          && SIGNERS.includes(String(p.signerAddress).toLowerCase()) && p.dataPoints && p.dataPoints.length === 1 && p.dataPoints[0].dataFeedId === feed);
        const seen = new Set(), out = [];
        for (const p of list) { const s = String(p.signerAddress).toLowerCase(); if (!seen.has(s)) { seen.add(s); out.push(p); } }
        if (out.length >= NEED) return out;
        lastErr = new Error(`${g}: only ${out.length} signers`);
      } catch (e) { lastErr = e; }
    }
    if (opts.throw && lastErr) throw lastErr;
    return [];
  }

  /** Median of the first 3 packages, the same value the contract will use (8 decimals, BigInt). */
  function priceOf(pkgs) {
    const v = pkgs.slice(0, NEED).map(p => units(p.dataPoints[0].value)).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
    return v[1];
  }

  /** Hex (no 0x) to append to the transaction data. */
  function buildPayload(pkgs) {
    if (!pkgs || pkgs.length < NEED) throw new Error('RedStone: not enough signed packages');
    const use = pkgs.slice(0, NEED);
    let h = '';
    for (const p of use) {
      const dp = p.dataPoints[0];
      h += feedHex(dp.dataFeedId) + hexN(units(dp.value), 32) + hexN(p.timestampMilliseconds, 6) + hexN(32, 4) + hexN(1, 3) + b64hex(p.signature);
    }
    h += hexN(use.length, 2) + hexN(0, 3) + MARKER;   // no unsigned metadata
    return h;
  }

  /** The bytes each signer signed (hex, no 0x), for checking signatures off chain. */
  function signedBytes(p) {
    const dp = p.dataPoints[0];
    return feedHex(dp.dataFeedId) + hexN(units(dp.value), 32) + hexN(p.timestampMilliseconds, 6) + hexN(32, 4) + hexN(1, 3);
  }

  const api = { GATEWAYS, SIGNERS, fetchPackages, buildPayload, priceOf, signedBytes, units };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.CavRedstone = api;
})(typeof self !== 'undefined' ? self : this);
