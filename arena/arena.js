/* CavFi Arena — standalone vanilla JS, ethers 5.7.2 UMD (loaded in arena.html), no build step. */
(function () {
  'use strict';

  // ------------------------------------------------------------------ constants

  var RPC_URL = 'https://rpc.testnet.dogeos.com';
  var CHAIN_ID = 6281971;
  var CHAIN_ID_HEX = '0x' + CHAIN_ID.toString(16);
  var EXPLORER = 'https://blockscout.testnet.dogeos.com';
  var WINDOW_SECS = 600; // 10 minutes, matches the contract's WINDOW
  var REFRESH_MS = 15000;

  var ARENA_ABI = [
    'function currentRound() view returns (uint256 id, uint64 start, uint64 end, uint64 stakingEndsAt, uint256 secondsLeft, uint256 pot, uint16 feeBps, bool live)',
    'function settleable() view returns (bool ready, uint256 id)',
    'function settle() returns (uint256)',
    'function roundTokens(uint256 id) view returns (address[] tokens, address[] pairs)',
    'function board(uint256 id) view returns (uint256[] pots, uint256[] startAvg, uint256[] endAvg, uint32[] startCnt, uint32[] endCnt)',
    'function spotPrices(uint256 id) view returns (uint256[] prices)',
    'function minStake() view returns (uint256)',
    'function stake(uint256 idx, uint256 amount)',
    'function betInfo(uint256 id, address user) view returns (tuple(uint64 start, uint64 end, uint16 feeBps, uint8 winnerMask, bool settled, uint256 staked, uint256 rollover, uint256 winnerStake, uint256 payout) round, uint256[] stakes, uint256 claimableAmount, bool hasClaimed)',
    'function userRounds(address user, uint256 offset, uint256 limit) view returns (uint256[] ids)',
    'function claim(uint256 id) returns (uint256)',
    'function claimMany(uint256[] ids) returns (uint256)'
  ];

  var ERC20_ABI = [
    'function symbol() view returns (string)',
    'function decimals() view returns (uint8)',
    'function balanceOf(address) view returns (uint256)',
    'function allowance(address owner, address spender) view returns (uint256)',
    'function approve(address spender, uint256 amount) returns (bool)'
  ];

  // ------------------------------------------------------------------ shared state

  var state = {
    readProvider: null,
    browserProvider: null,
    signer: null,
    account: null,
    arenaAddr: null,
    kingsAddr: null,
    wdogeAddr: null,
    arena: null, // read-only contract
    kings: null, // read-only contract
    inited: false,
    pickedIdx: null,
    tokens: [], // [{ address, symbol }]
    round: null,
    board: null,
    spots: null,
    settleInfo: null,
    minStake: null,
    kingsBalance: null,
    roundEndMs: null,
    busy: false
  };

  // ------------------------------------------------------------------ top-level account/signer helpers

  function getAccount() {
    return state.account;
  }

  function getSigner() {
    return state.signer;
  }

  // ------------------------------------------------------------------ small utils

  function $(id) { return document.getElementById(id); }

  function sanitizeSymbol(s) {
    return String(s == null ? '' : s).replace(/[<>&"'\\]/g, '').trim().slice(0, 16);
  }

  function fmt(bn, decimals, maxFrac) {
    if (bn == null) return '—';
    try {
      var s = ethers.utils.formatUnits(bn, decimals == null ? 18 : decimals);
      var n = Number(s);
      if (!isFinite(n)) return s;
      var frac = maxFrac == null ? 4 : maxFrac;
      return n.toLocaleString(undefined, { maximumFractionDigits: frac });
    } catch (e) {
      return '—';
    }
  }

  function pct(n, digits) {
    if (n == null || !isFinite(n)) return '—';
    var d = digits == null ? 2 : digits;
    return (n > 0 ? '+' : '') + n.toFixed(d) + '%';
  }

  function pad2(n) { return n < 10 ? '0' + n : '' + n; }

  function mmss(totalSeconds) {
    var s = Math.max(0, Math.floor(totalSeconds));
    var h = Math.floor(s / 3600);
    var m = Math.floor((s % 3600) / 60);
    var sec = s % 60;
    if (h > 0) return h + ':' + pad2(m) + ':' + pad2(sec);
    return pad2(m) + ':' + pad2(sec);
  }

  function txLink(hash) {
    return EXPLORER.replace(/\/$/, '') + '/tx/' + hash;
  }

  // ------------------------------------------------------------------ toasts

  function toast(kind, message, hash) {
    var host = $('toasts');
    if (!host) return;
    var el = document.createElement('div');
    el.className = 'toast ' + (kind === 'bad' ? 'bad' : 'ok');
    var html = '<div>' + message.replace(/</g, '&lt;') + '</div>';
    if (hash) html += '<div><a href="' + txLink(hash) + '" target="_blank" rel="noopener">View transaction</a></div>';
    el.innerHTML = html;
    host.appendChild(el);
    setTimeout(function () {
      if (el.parentNode) el.parentNode.removeChild(el);
    }, 7000);
  }

  function friendlyError(e) {
    var msg = '';
    if (e) {
      msg = (e.error && e.error.message) || (e.data && e.data.message) || e.reason || e.message || '';
    }
    if (!msg) msg = 'Transaction failed.';
    var marker = 'KingArena: ';
    var idx = msg.indexOf(marker);
    if (idx !== -1) {
      var reason = msg.slice(idx + marker.length).split(/["'\n]/)[0].trim();
      var map = {
        STAKING_CLOSED: 'Staking is closed for this round.',
        MIN_STAKE: 'That amount is below the minimum stake.',
        BAD_TOKEN: 'That token is not part of this round.',
        NOT_STARTED: 'The arena has not started yet.',
        TOO_EARLY: 'This round cannot be settled yet.',
        NO_NEXT_ROUND: 'The next round has not opened yet.',
        NOTHING_TO_CLAIM: 'There is nothing to claim.',
        ALREADY_CLAIMED: 'This round was already claimed.',
        NOT_SETTLED: 'This round has not been settled yet.'
      };
      return map[reason] || reason.replace(/_/g, ' ').toLowerCase();
    }
    if (/user rejected|user denied/i.test(msg)) return 'Transaction rejected.';
    if (/insufficient funds/i.test(msg)) return 'Insufficient funds for gas.';
    return msg.length > 140 ? msg.slice(0, 140) + '…' : msg;
  }

  // ------------------------------------------------------------------ wallet connection

  async function ensureChain(ethereum) {
    var current = await ethereum.request({ method: 'eth_chainId' });
    if (current === CHAIN_ID_HEX) return;
    try {
      await ethereum.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: CHAIN_ID_HEX }]
      });
    } catch (switchErr) {
      if (switchErr && switchErr.code === 4902) {
        await ethereum.request({
          method: 'wallet_addEthereumChain',
          params: [{
            chainId: CHAIN_ID_HEX,
            chainName: 'DOGE Testnet',
            nativeCurrency: { name: 'DOGE', symbol: 'DOGE', decimals: 18 },
            rpcUrls: [RPC_URL],
            blockExplorerUrls: [EXPLORER]
          }]
        });
      } else {
        throw switchErr;
      }
    }
  }

  async function connectWallet() {
    var ethereum = window.ethereum;
    if (!ethereum) {
      toast('bad', 'No wallet found. Install an EVM wallet to continue.');
      return;
    }
    try {
      await ethereum.request({ method: 'eth_requestAccounts' });
      await ensureChain(ethereum);
      state.browserProvider = new ethers.providers.Web3Provider(ethereum, 'any');
      var signer = state.browserProvider.getSigner();
      var addr = await signer.getAddress();
      state.signer = signer;
      state.account = addr;
      updateWalletButton();
      await loadAll();
    } catch (e) {
      toast('bad', friendlyError(e));
    }
  }

  function updateWalletButton() {
    var btn = $('walletBtn');
    if (!btn) return;
    if (state.account) {
      btn.classList.add('on');
      btn.textContent = state.account.slice(0, 6) + '…' + state.account.slice(-4);
    } else {
      btn.classList.remove('on');
      btn.textContent = 'Connect wallet';
    }
  }

  function wireWalletEvents() {
    var ethereum = window.ethereum;
    if (!ethereum || !ethereum.on) return;
    ethereum.on('accountsChanged', function (accounts) {
      if (!accounts || accounts.length === 0) {
        state.account = null;
        state.signer = null;
      } else {
        state.browserProvider = new ethers.providers.Web3Provider(ethereum, 'any');
        state.signer = state.browserProvider.getSigner();
        state.account = accounts[0];
      }
      updateWalletButton();
      loadAll();
    });
    ethereum.on('chainChanged', function () {
      window.location.reload();
    });
  }

  // ------------------------------------------------------------------ config / init

  async function loadConfig() {
    var cfg = {};
    try {
      var res = await fetch('addresses.json', { cache: 'no-store' });
      if (res.ok) cfg = await res.json();
    } catch (e) {
      // addresses.json missing is fine; fall through to query override / no-deploy banner
    }
    var params = new URLSearchParams(window.location.search);
    var override = params.get('arena');
    state.arenaAddr = override && ethers.utils.isAddress(override) ? override : (cfg.arena || null);
    state.kingsAddr = cfg.kings || null;
    state.wdogeAddr = cfg.wdoge || null;
    return cfg;
  }

  async function show() {
    if (state.inited) return;
    state.inited = true;

    $('walletBtn').addEventListener('click', connectWallet);
    $('arMax').addEventListener('click', onMaxClick);
    $('arAmt').addEventListener('input', renderForm);
    $('arCta').addEventListener('click', onCtaClick);
    $('arSettle').addEventListener('click', onSettleClick);
    $('arClaimAll').addEventListener('click', onClaimAllClick);

    await loadConfig();

    if (!state.arenaAddr || !state.kingsAddr) {
      $('arNoDeploy').hidden = false;
      $('arStatus').innerHTML = '<i class="dot"></i><span>Not deployed</span>';
      $('arCountSub').textContent = 'Waiting for a deployment.';
      return;
    }

    state.readProvider = new ethers.providers.StaticJsonRpcProvider(RPC_URL, { chainId: CHAIN_ID, name: 'dogeos' });
    state.arena = new ethers.Contract(state.arenaAddr, ARENA_ABI, state.readProvider);
    state.kings = new ethers.Contract(state.kingsAddr, ERC20_ABI, state.readProvider);

    if (window.ethereum) {
      try {
        var ethereum = window.ethereum;
        var accounts = await ethereum.request({ method: 'eth_accounts' });
        if (accounts && accounts.length > 0) {
          await ensureChain(ethereum).catch(function () {});
          state.browserProvider = new ethers.providers.Web3Provider(ethereum, 'any');
          state.signer = state.browserProvider.getSigner();
          state.account = accounts[0];
          updateWalletButton();
        }
      } catch (e) { /* ignore silent reconnect failures */ }
      wireWalletEvents();
    }

    startTicker();
    await loadAll();
    setInterval(loadAll, REFRESH_MS);
  }

  // ------------------------------------------------------------------ data loading

  async function loadAll() {
    try {
      var round = await state.arena.currentRound();
      state.round = round;
      state.roundEndMs = Date.now() + round.secondsLeft.toNumber() * 1000;
      state.settleInfo = await state.arena.settleable();
      state.minStake = await state.arena.minStake();

      if (round.id.toNumber() !== 0) {
        var rt = await state.arena.roundTokens(round.id);
        var tokenList = [];
        for (var i = 0; i < rt.tokens.length; i++) {
          var sym = '?';
          try {
            var erc = new ethers.Contract(rt.tokens[i], ERC20_ABI, state.readProvider);
            sym = sanitizeSymbol(await erc.symbol());
          } catch (e) { sym = rt.tokens[i].slice(0, 6); }
          tokenList.push({ address: rt.tokens[i], symbol: sym || rt.tokens[i].slice(0, 6) });
        }
        state.tokens = tokenList;
        state.board = await state.arena.board(round.id);
        state.spots = await state.arena.spotPrices(round.id);
      } else {
        state.tokens = [];
        state.board = null;
        state.spots = null;
      }

      if (state.account) {
        state.kingsBalance = await state.kings.balanceOf(state.account);
      } else {
        state.kingsBalance = null;
      }

      renderClock();
      renderTokens();
      renderForm();
      renderSettle();
      await renderBets();
    } catch (e) {
      // keep last good UI on transient RPC errors
      console.error('CavFi Arena load failed', e);
    }
  }

  // ------------------------------------------------------------------ clock / countdown

  function roundPhase() {
    var r = state.round;
    if (!r || r.id.toNumber() === 0) return 'none';
    var now = Math.floor(Date.now() / 1000);
    var start = r.start.toNumber();
    var end = r.end.toNumber();
    var stakingEndsAt = r.stakingEndsAt.toNumber();
    if (now < start + WINDOW_SECS) return 'startWindow';
    if (r.live && now < stakingEndsAt) return 'open';
    if (r.live) return 'endWindow';
    return 'ended';
  }

  function statusLabel(phase) {
    switch (phase) {
      case 'startWindow': return ['open', 'Start price window'];
      case 'open': return ['open', 'Staking open'];
      case 'endWindow': return ['closing', 'Staking closed · end price window'];
      case 'ended': return ['ended', 'Waiting for the next round'];
      default: return ['ended', 'Waiting for the next round'];
    }
  }

  function renderClock() {
    var r = state.round;
    var elId = $('arRoundId');
    if (!r || r.id.toNumber() === 0) {
      elId.textContent = 'Round —';
      $('arStatus').innerHTML = '<i class="dot"></i><span>Waiting for the next round</span>';
      $('arStatus').className = 'ar-status ended';
      $('arCount').textContent = '--:--';
      $('arCountSub').textContent = 'The next round opens on the first stake or settle.';
      $('arFill').style.width = '0%';
      $('arZoneS').style.width = '0%';
      $('arZoneE').style.width = '0%';
      $('arPot').textContent = '—';
      $('arFee').textContent = '—';
      $('arMinFig').textContent = state.minStake ? fmt(state.minStake, 18, 0) : '—';
      return;
    }
    elId.textContent = 'Round ' + r.id.toString();
    var phase = roundPhase();
    var sl = statusLabel(phase);
    $('arStatus').className = 'ar-status ' + sl[0];
    $('arStatus').innerHTML = '<i class="dot"></i><span>' + sl[1] + '</span>';

    var total = r.end.toNumber() - r.start.toNumber();
    var elapsed = Math.min(total, Math.max(0, Math.floor(Date.now() / 1000) - r.start.toNumber()));
    var fillPct = total > 0 ? Math.min(100, (elapsed / total) * 100) : 0;
    $('arFill').style.width = fillPct + '%';
    $('arZoneS').style.width = total > 0 ? Math.min(100, (WINDOW_SECS / total) * 100) + '%' : '0%';
    $('arZoneE').style.width = total > 0 ? Math.min(100, (WINDOW_SECS / total) * 100) + '%' : '0%';

    $('arPot').textContent = fmt(r.pot, 18, 0);
    $('arFee').textContent = (r.feeBps / 100).toFixed(2) + '%';
    $('arMinFig').textContent = state.minStake ? fmt(state.minStake, 18, 0) : '—';
    $('arFormRound').textContent = 'Round ' + r.id.toString();

    tickCountdown();
  }

  function tickCountdown() {
    var r = state.round;
    if (!r || r.id.toNumber() === 0 || !state.roundEndMs) {
      $('arCount').textContent = '--:--';
      return;
    }
    var remaining = Math.max(0, Math.round((state.roundEndMs - Date.now()) / 1000));
    $('arCount').textContent = mmss(remaining);
    var phase = roundPhase();
    if (phase === 'open') $('arCountSub').textContent = 'Until staking closes & the end window begins.';
    else if (phase === 'startWindow') $('arCountSub').textContent = 'Setting the start price — staking is open.';
    else if (phase === 'endWindow') $('arCountSub').textContent = 'Setting the end price — staking is closed.';
    else $('arCountSub').textContent = 'Round ended — waiting to be settled.';
  }

  function startTicker() {
    setInterval(function () {
      tickCountdown();
      renderForm();
    }, 1000);
  }

  // ------------------------------------------------------------------ token cards

  function tokenChangePct(i) {
    if (!state.board) return null;
    var startAvg = state.board.startAvg[i];
    var endAvg = state.board.endAvg[i];
    var endCnt = state.board.endCnt[i];
    var basis = (endCnt && endCnt > 0) ? endAvg : (state.spots ? state.spots[i] : null);
    if (!basis || startAvg.isZero()) return null;
    var startN = Number(ethers.utils.formatUnits(startAvg, 18));
    var basisN = Number(ethers.utils.formatUnits(basis, 18));
    if (!startN) return null;
    return ((basisN - startN) / startN) * 100;
  }

  function renderTokens() {
    var host = $('arTokens');
    host.innerHTML = '';
    if (!state.round || state.round.id.toNumber() === 0 || !state.tokens.length) {
      host.innerHTML = '<div class="empty">No round is live right now.</div>';
      return;
    }
    var pot = state.round.pot;
    var feeBps = state.round.feeBps;
    var potN = Number(ethers.utils.formatUnits(pot, 18));
    var feeFrac = feeBps / 10000;

    var changes = state.tokens.map(function (_, i) { return tokenChangePct(i); });
    var bestChange = Math.max.apply(null, changes.filter(function (c) { return c != null; }).concat([-Infinity]));

    state.tokens.forEach(function (tok, i) {
      var tokenPot = state.board ? state.board.pots[i] : ethers.BigNumber.from(0);
      var tokenPotN = Number(ethers.utils.formatUnits(tokenPot, 18));
      var share = potN > 0 ? (tokenPotN / potN) * 100 : 0;
      var change = changes[i];
      var isLead = change != null && change === bestChange && bestChange !== -Infinity;

      var payoutMult = (!tokenPot.isZero() && potN > 0)
        ? ((potN * (1 - feeFrac)) / tokenPotN)
        : null;

      var myStake = null;
      if (state.myBetStakes && state.myBetStakes[i] != null) myStake = state.myBetStakes[i];

      var chgClass = change == null ? 'flat' : (change > 0.0001 ? 'up' : (change < -0.0001 ? 'down' : 'flat'));
      var card = document.createElement('button');
      card.type = 'button';
      card.className = 'ar-tok' + (isLead ? ' lead' : '') + (state.pickedIdx === i ? ' on' : '');
      card.style.setProperty('--i', i);
      card.innerHTML =
        '<div class="ar-tok-top">' +
          '<div class="ar-tok-nm"><b>' + tok.symbol + '</b><small>' + tok.address.slice(0, 6) + '…' + tok.address.slice(-4) + '</small></div>' +
          (isLead ? '<span class="ar-lead">Leading</span>' : '') +
        '</div>' +
        '<div class="ar-chg ' + chgClass + '">' + (change == null ? '—' : pct(change)) + '</div>' +
        '<div class="ar-basis">' + (state.board && state.board.endCnt[i] > 0 ? 'vs end-window price' : 'vs start price (live)') + '</div>' +
        '<div class="ar-meter"><i style="width:' + Math.min(100, share) + '%"></i></div>' +
        '<div class="ar-kv"><span>Pot share</span><b>' + share.toFixed(1) + '%</b></div>' +
        '<div class="ar-kv"><span>Token pot</span><b>' + tokenPotN.toLocaleString(undefined, { maximumFractionDigits: 0 }) + '</b></div>' +
        '<div class="ar-kv"><span>Payout if it wins</span><b>' + (payoutMult == null ? '—' : payoutMult.toFixed(2) + 'x') + '</b></div>' +
        (myStake != null && !myStake.isZero()
          ? '<div class="ar-kv mine"><span>My stake</span><b>' + fmt(myStake, 18, 0) + '</b></div>'
          : '');
      card.addEventListener('click', function () {
        state.pickedIdx = i;
        renderPick();
        renderForm();
      });
      host.appendChild(card);
    });

    renderPick();
  }

  function renderPick() {
    var host = $('arPick');
    host.innerHTML = '';
    state.tokens.forEach(function (tok, i) {
      var chip = document.createElement('button');
      chip.type = 'button';
      chip.className = 'chip';
      chip.setAttribute('aria-pressed', state.pickedIdx === i ? 'true' : 'false');
      chip.textContent = tok.symbol;
      chip.addEventListener('click', function () {
        state.pickedIdx = i;
        renderPick();
        renderTokens();
        renderForm();
      });
      host.appendChild(chip);
    });
  }

  // ------------------------------------------------------------------ stake form

  function parseAmount() {
    var raw = ($('arAmt').value || '').trim();
    if (!raw) return null;
    try {
      return ethers.utils.parseUnits(raw, 18);
    } catch (e) {
      return null;
    }
  }

  function onMaxClick() {
    if (!state.kingsBalance) return;
    $('arAmt').value = ethers.utils.formatUnits(state.kingsBalance, 18);
    renderForm();
  }

  function renderForm() {
    var cta = $('arCta');
    var bal = $('arBal');
    var min = $('arMin');
    bal.textContent = 'Balance ' + (state.kingsBalance ? fmt(state.kingsBalance, 18, 2) : '—');
    min.textContent = 'Min ' + (state.minStake ? fmt(state.minStake, 18, 0) : '—');

    var details = $('arDetails');
    details.innerHTML = '';

    if (!state.round || state.round.id.toNumber() === 0) {
      cta.disabled = true;
      cta.textContent = 'No round is live';
      return;
    }
    if (!state.account) {
      cta.disabled = true;
      cta.textContent = 'Connect wallet';
      return;
    }
    var phase = roundPhase();
    var stakingOpen = phase === 'startWindow' || phase === 'open';
    if (!stakingOpen) {
      cta.disabled = true;
      cta.textContent = 'Staking closed';
      return;
    }
    if (state.pickedIdx == null) {
      cta.disabled = true;
      cta.textContent = 'Select a token';
      return;
    }
    var amount = parseAmount();
    if (!amount || amount.isZero()) {
      cta.disabled = true;
      cta.textContent = 'Enter an amount';
      return;
    }
    if (state.minStake && amount.lt(state.minStake)) {
      cta.disabled = true;
      cta.textContent = 'Minimum stake is ' + fmt(state.minStake, 18, 0) + ' KingS';
      return;
    }
    if (state.kingsBalance && amount.gt(state.kingsBalance)) {
      cta.disabled = true;
      cta.textContent = 'Insufficient KingS balance';
      return;
    }

    details.innerHTML =
      '<div class="row"><dt>Backing</dt><dd>' + (state.tokens[state.pickedIdx] ? state.tokens[state.pickedIdx].symbol : '—') + '</dd></div>' +
      '<div class="row"><dt>Amount</dt><dd>' + fmt(amount, 18, 4) + ' KingS</dd></div>';

    cta.disabled = state.busy;
    cta.textContent = state.busy ? 'Working…' : 'Stake';
  }

  async function onCtaClick() {
    if (state.busy) return;
    var amount = parseAmount();
    var idx = state.pickedIdx;
    if (amount == null || idx == null || !state.signer) return;
    state.busy = true;
    renderForm();
    try {
      var kingsW = new ethers.Contract(state.kingsAddr, ERC20_ABI, state.signer);
      var arenaW = new ethers.Contract(state.arenaAddr, ARENA_ABI, state.signer);
      var allowance = await kingsW.allowance(state.account, state.arenaAddr);
      if (allowance.lt(amount)) {
        var approveTx = await kingsW.approve(state.arenaAddr, amount);
        toast('ok', 'Approving KingS…', approveTx.hash);
        await approveTx.wait();
        toast('ok', 'KingS approved.', approveTx.hash);
      }
      var tx = await arenaW.stake(idx, amount);
      toast('ok', 'Stake submitted…', tx.hash);
      await tx.wait();
      toast('ok', 'Stake confirmed.', tx.hash);
      $('arAmt').value = '';
    } catch (e) {
      toast('bad', friendlyError(e));
    } finally {
      state.busy = false;
      await loadAll();
    }
  }

  // ------------------------------------------------------------------ settle

  function renderSettle() {
    var btn = $('arSettle');
    if (state.settleInfo && state.settleInfo.ready) {
      btn.hidden = false;
      btn.textContent = 'Settle round ' + state.settleInfo.id.toString();
      btn.disabled = state.busy;
    } else {
      btn.hidden = true;
    }
  }

  async function onSettleClick() {
    if (!state.signer) {
      toast('bad', 'Connect a wallet to settle.');
      return;
    }
    if (state.busy) return;
    state.busy = true;
    renderSettle();
    try {
      var arenaW = new ethers.Contract(state.arenaAddr, ARENA_ABI, state.signer);
      var tx = await arenaW.settle();
      toast('ok', 'Settling round…', tx.hash);
      await tx.wait();
      toast('ok', 'Round settled.', tx.hash);
    } catch (e) {
      toast('bad', friendlyError(e));
    } finally {
      state.busy = false;
      await loadAll();
    }
  }

  // ------------------------------------------------------------------ my bets

  function betResultLabel(info) {
    var r = info.round;
    if (!r.settled) {
      return r.start.toNumber() === 0 ? ['wait', 'Pending'] : ['live', 'In progress'];
    }
    if (r.winnerStake.isZero()) return ['wait', 'Rolled over'];
    var won = info.stakes.some(function (s, i) {
      return !s.isZero() && ((r.winnerMask >> i) & 1) === 1;
    });
    return won ? ['won', 'Won'] : ['lost', 'Lost'];
  }

  async function renderBets() {
    var host = $('arBetList');
    var claimAllBtn = $('arClaimAll');
    if (!state.account) {
      host.innerHTML = '<div class="empty">Connect your wallet to see your bets.</div>';
      claimAllBtn.hidden = true;
      state.myBetStakes = null;
      renderTokens();
      return;
    }
    try {
      var ids = await state.arena.userRounds(state.account, 0, 20);
      if (!ids.length) {
        host.innerHTML = '<div class="empty">No bets yet — back a token above.</div>';
        claimAllBtn.hidden = true;
        state.myBetStakes = null;
        if (state.round && state.round.id.toNumber() !== 0) renderTokens();
        return;
      }
      var infos = await Promise.all(ids.map(function (id) { return state.arena.betInfo(id, state.account); }));

      // Sync current round's "my stake" into the token cards.
      state.myBetStakes = null;
      if (state.round && state.round.id.toNumber() !== 0) {
        for (var k = 0; k < ids.length; k++) {
          if (ids[k].eq(state.round.id)) { state.myBetStakes = infos[k].stakes; break; }
        }
        renderTokens();
      }

      var claimableIds = [];
      host.innerHTML = '';
      for (var i = ids.length - 1; i >= 0; i--) {
        var id = ids[i];
        var info = infos[i];
        var tag = betResultLabel(info);
        var stakesHtml = info.stakes.map(function (s, si) {
          if (s.isZero()) return '';
          var isWin = ((info.round.winnerMask >> si) & 1) === 1;
          return '<span class="ar-stk' + (info.round.settled && isWin ? ' win' : '') + '">#' + si + ' · ' + fmt(s, 18, 0) + '</span>';
        }).join('');
        var canClaim = info.claimableAmount && !info.claimableAmount.isZero() && !info.hasClaimed;
        if (canClaim) claimableIds.push(id);

        var row = document.createElement('div');
        row.className = 'ar-bet' + (tag[0] === 'won' ? ' win' : '');
        row.innerHTML =
          '<div class="ar-bet-h"><b>Round ' + id.toString() + '</b><span class="ar-tag ' + tag[0] + '">' + tag[1] + '</span></div>' +
          '<div class="ar-stakes">' + stakesHtml + '</div>' +
          '<div class="ar-bet-f">' +
            '<span>' + (canClaim ? fmt(info.claimableAmount, 18, 2) + ' KingS claimable' : (info.hasClaimed ? 'Claimed' : '—')) + '</span>' +
            (canClaim ? '<button class="ar-btn solid" type="button" data-claim="' + id.toString() + '">Claim</button>' : '') +
          '</div>';
        host.appendChild(row);
      }

      host.querySelectorAll('[data-claim]').forEach(function (btn) {
        btn.addEventListener('click', function () { onClaimClick(btn.getAttribute('data-claim')); });
      });

      claimAllBtn.hidden = claimableIds.length === 0;
      claimAllBtn.disabled = state.busy;
      state.claimableIds = claimableIds;
    } catch (e) {
      console.error('Failed to load bets', e);
    }
  }

  async function onClaimClick(idStr) {
    if (!state.signer || state.busy) return;
    state.busy = true;
    try {
      var arenaW = new ethers.Contract(state.arenaAddr, ARENA_ABI, state.signer);
      var tx = await arenaW.claim(idStr);
      toast('ok', 'Claiming round ' + idStr + '…', tx.hash);
      await tx.wait();
      toast('ok', 'Claimed.', tx.hash);
    } catch (e) {
      toast('bad', friendlyError(e));
    } finally {
      state.busy = false;
      await loadAll();
    }
  }

  async function onClaimAllClick() {
    if (!state.signer || state.busy || !state.claimableIds || !state.claimableIds.length) return;
    state.busy = true;
    try {
      var arenaW = new ethers.Contract(state.arenaAddr, ARENA_ABI, state.signer);
      var tx = await arenaW.claimMany(state.claimableIds);
      toast('ok', 'Claiming ' + state.claimableIds.length + ' round(s)…', tx.hash);
      await tx.wait();
      toast('ok', 'All claimed.', tx.hash);
    } catch (e) {
      toast('bad', friendlyError(e));
    } finally {
      state.busy = false;
      await loadAll();
    }
  }

  // ------------------------------------------------------------------ expose

  window.CavArena = { show: show };
})();
