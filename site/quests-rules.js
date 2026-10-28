/* CavFi daily quests: one shared set of rules for the website and the CavFi bot.
   Every UTC day has 3 quests: "say gm" or "say gn" (alternating), plus 2 more picked from the list
   below by the day number, so everyone gets the same 3 and anyone can recompute them.
   A quest counts when the wallet sent a successful transaction that day to the right CavFi contract
   with one of the listed functions (matched by the 4-byte function selector). */
(function(root, factory){
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.CavQuests = factory();
})(typeof self !== 'undefined' ? self : this, function(){
  'use strict';
  var POOL = [
    {id: 'swap',   key: ['router'],         sel: ['0x7ff36ab5', '0x18cbafe5', '0x38ed1739'], title: 'Make a swap',              hint: 'Any swap on the Swap page', view: 'swap'},
    {id: 'liq',    key: ['router'],         sel: ['0xe8e33700', '0xf305d719'],               title: 'Add liquidity',            hint: 'Any amount to any pool', view: 'liq'},
    {id: 'farm',   key: ['farm', 'stake'],  sel: ['0xe2bbb158', '0x608fc37a', '0xddc63262'], title: 'Stake or harvest on Farms', hint: 'Deposit, or collect your KingS', view: 'farm'},
    {id: 'launch', key: ['launch'],         sel: ['0xcce7ec13', '0x6a272462', '0x2fde70d1'], title: 'Trade on the Launchpad',   hint: 'Buy or sell a meme, or launch one', view: 'launch'},
    {id: 'arena',  key: ['arena'],          sel: ['0x7b0472f0'],                             title: 'Back a token in the Arena', hint: 'Any stake in the current round', href: 'arena.html'},
    {id: 'nft',    key: ['nft'],            sel: ['0xa0712d68', '0x0fbf0a93', '0x4e71d92d'], title: 'Mint, stake or claim a Cavalier', hint: 'On the NFTs page', view: 'nft'},
    {id: 'limit',  key: ['limit'],          sel: ['0x391560b2', '0xb0987adb'],               title: 'Place a limit order',      hint: 'On the Swap page, Limit tab', view: 'swap'},
    {id: 'dca',    key: ['dca'],            sel: ['0x7b070932', '0xd5c55b52'],               title: 'Start an auto-buy',        hint: 'Swap page, Auto-buy', view: 'swap'},
    {id: 'name',   key: ['names'],          sel: ['0xf2c298be', '0x38e74feb'],               title: 'Claim or set a .cav name', hint: 'On the Names page', view: 'names'},
    // added later: "from" is the first UTC day they can be picked, so earlier days keep exactly the same quests
    {id: 'predict', key: ['predict', 'predictV1'], sel: ['0x8decaec0'],                             title: 'Call the DOGE price',      hint: 'Back YES or NO on any open market', view: 'predict', from: 20752},
    {id: 'duel',   key: ['duel'],           sel: ['0xc139da6f', '0x19b05f49'],               title: 'Start or accept a duel',   hint: 'Predict page, Arena duels tab', href: '#duels', from: 20752},
    {id: 'guess',  key: ['guess', 'guessV1'], sel: ['0x1e997a6d'],                             title: 'Guess the DOGE price',     hint: 'Free: Predict page, Free guess tab', href: '#guess', from: 20754},
    {id: 'callout', key: ['callouts'],       sel: ['0xf55332ab'],                             title: 'Call a Launchpad token',   hint: 'Open a token on the Launch page, press Call it', view: 'launch', from: 20756}
  ];
  var GM = {id: 'gm', key: ['gm'], sel: ['0xc0129d43'], title: 'Say gm', hint: 'GM card on the home page', view: 'home'};
  var GN = {id: 'gn', key: ['gm'], sel: ['0x3118f543'], title: 'Say gn', hint: 'GM card on the home page', view: 'home'};

  function dayOf(ts){ return Math.floor(ts / 86400); }
  function has(A, q){ return q.key.some(function(k){ return !!A[k]; }); }

  /** The 3 quests of a UTC day (only quests whose contracts exist in this addresses.json). */
  function questsFor(day, A){
    var first = day % 2 === 0 ? GM : GN;
    var list = [];
    if (has(A, first)) list.push(first);
    var pool = POOL.filter(function(q){ return has(A, q) && (!q.from || day >= q.from); });
    var seed = Math.imul(day, 0x9E3779B1) >>> 0;
    while (list.length < 3 && pool.length){
      seed = (Math.imul(seed, 1103515245) + 12345) >>> 0;
      list.push(pool.splice(seed % pool.length, 1)[0]);
    }
    return list;
  }

  /** txs: [{to, input, ok, ts}] of ONE wallet. Returns which of the day's quests it completed. */
  function evaluate(txs, A, day){
    var qs = questsFor(day, A);
    var done = qs.map(function(q){
      var targets = q.key.map(function(k){ return (A[k] || '').toLowerCase(); }).filter(Boolean);
      return txs.some(function(t){
        if (!t.ok || dayOf(t.ts) !== day || !t.to) return false;
        var sel = (t.input || '').slice(0, 10).toLowerCase();
        return targets.indexOf(t.to.toLowerCase()) >= 0 && q.sel.indexOf(sel) >= 0;
      });
    });
    return {quests: qs, done: done, count: done.filter(Boolean).length};
  }

  /** Every contract a quest can be completed at (for scanning a day's transactions). */
  function contracts(A){
    var keys = {};
    POOL.concat([GM, GN]).forEach(function(q){ q.key.forEach(function(k){ if (A[k]) keys[A[k].toLowerCase()] = true; }); });
    return Object.keys(keys);
  }

  return {questsFor: questsFor, evaluate: evaluate, contracts: contracts, dayOf: dayOf, PER_DAY: 3};
});
