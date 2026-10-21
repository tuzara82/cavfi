# CavFi security review (testnet)

Date: 21 Oct 2026 · Scope: all contracts in `src/`, the website (`site/index.html`) and the bot (`bot/cavfi-bot.mjs`).
Method: Slither static analysis (94 detectors), invariant fuzzing (3 suites, 36,000 random calls each), the unit
test suite (56 tests) and a manual review. This is a self-review for a testnet project, not a professional audit.

## Fixed in this round

| # | Severity | Where | Issue | Fix |
|---|---|---|---|---|
| 1 | **High** | website | Token names and symbols read from any contract were put into the page as HTML. Anyone could create a token named like `<b onmouseover=…>` and pair it; the Liquidity, Stats and Farms pages then ran its markup (confirmed: 17 injected elements on the old page). | Every name and symbol from chain or local storage is now stripped of markup characters and length-limited (`cleanSym`, `cleanName`). Verified with a hostile token: nothing injected. |
| 2 | Medium | website | Swap routes could pass through any token someone paired up. | Middle hops now only use CavFi's listed tokens. |
| 3 | Medium | bot | The pool fixer could take price evidence from pools of unknown tokens and trade them. | It only trades and reads prices from pools of listed tokens, ignores pools under `REBALANCE_MIN_POOL_USD`, and still needs two agreeing routes and a per-trade cap. |

## Reviewed, no change needed

| Slither finding | Why it is safe |
|---|---|
| reentrancy-eth in `KingLaunch.create/_buy` | All external entry points (`create`, `buy`, `sell`) are `nonReentrant`; state is written before DOGE is sent. MemeToken has no transfer hooks. |
| reentrancy-balance in `KingLimit.fill` | `fill`, `place*` and `cancel` are `nonReentrant`; the router gets an exact allowance; the maker is protected by `minOut` measured from the contract's own balance change. |
| reentrancy-balance in `KingVote.fundFarm` | Owner-only and moves only KingS (a standard ERC-20). |
| arbitrary-send-eth in `KingLaunch._graduate` | Sends only to the WDOGE contract (`deposit`). |
| divide-before-multiply | Intentional rounding in the pool's favour (curve buys round up, sells round down; farm rates floor). Fuzzed. |
| incorrect-equality, unused-return, missing-zero-check, calls-loop | Standard patterns (Uniswap V2 / MasterChef) or owner-set addresses; no exploit path. |

## Invariants that hold under fuzzing

* **Launchpad**: the contract always holds exactly the DOGE it owes all curves; unsold tokens + the 200M LP reserve are
  always in the contract; a graduated token leaves nothing behind.
* **Limit orders**: every open order is fully backed by tokens in the contract; it never holds loose DOGE.
* **Voting**: locked KingS = KingS held; total votes ≤ locked KingS; per-pool tallies always add up to the total.

## Known limits (by design, worth knowing)

* Owners: you own the factory fee switch, launchpad parameters, staking, badges and social contracts; KingVote owns the
  farm. On a mainnet these keys should sit in a multisig with a timelock.
* The launchpad curve and limit orders can be front-run like any public AMM; users are protected by slippage limits.
* Comments, referrals and the leaderboard can be gamed with many wallets (sybils). Points have no value.
* The bot holds a hot key on your PC (encrypted with Windows DPAPI). Keep only small amounts in that wallet.
* Before any mainnet launch: a professional audit, a bug bounty and a multisig for every owner role.
