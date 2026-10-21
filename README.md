# CavFi: the royal DeFi court of DogeOS

**Live:** https://cavfi.com · **Network:** DogeOS Chikyu testnet (chain ID 6281971)

CavFi is a full DeFi hub on DogeOS testnet, with a crowned Cavalier King Charles Spaniel as its mascot.
Every action is an on-chain transaction from the user's own wallet; there is no backend and no custody.

## What it does

| Area | What users can do |
|---|---|
| **Swap** | Trade DOGE, KingS, the official DogeOS faucet tokens (LBTC, WETH, USD1, USDC, USDT) and CavFi test stables. Multi-hop routing, price-impact and mispriced-pool warnings, candle chart (1H/1D/7D). |
| **Limit orders** | Park tokens at a target price; anyone (including the CavFi bot) fills them when the pools pay it, earning a 0.1% tip. |
| **Liquidity** | Uniswap V2-style pools, 0.3% fee: 0.25% to LPs, 0.05% protocol. |
| **Farms & staking** | Stake LP or single tokens (DOGE, KingS, stables, graduated memes) and earn KingS every second. |
| **Voting** | Lock KingS (1 KingS = 1 vote) and split votes across farms; once a week the farm weights follow. |
| **Launchpad** | Launch a meme token in one transaction. 800M of 1B tokens sell on a bonding curve; when it fills, the DOGE and the other 200M tokens become a CavFi pool with burned LP (locked forever). Comments, top holders, trending by 1h volume. |
| **Stats** | TVL, volume, fees, per-pool tables, price charts, recent swaps, a points leaderboard. |
| **Portfolio** | Everything a wallet holds on CavFi, valued in USD. |
| **Social** | Referral links (+25% of invitees' points), soulbound "Royal Court" achievement badges with on-chain SVG art. |
| **App** | Installable PWA (Android, iOS, desktop). |
| **Bot** | Node.js keeper: fills limit orders, fixes mispriced pools, applies weekly votes, awards badges, posts to Telegram. |

## Repository layout

```
site/        index.html: the whole web app (vanilla JS + ethers v5), addresses.json, PWA files
contracts/   Foundry project: all Solidity contracts, tests (62 incl. invariant fuzzing), deploy scripts
bot/         cavfi-bot.mjs: keeper + Telegram alerts; Windows autostart scripts
publish/     the folder uploaded to hosting (copy of site/)
```

## Contracts (all verified on https://blockscout.testnet.dogeos.com)

| Contract | Address | Role |
|---|---|---|
| KingFactory | `0xf040D9D599414211079b8654108952c1f7A4E7F0` | Creates pools, protocol fee switch |
| KingRouter | `0x736C94259f16437C0cDbBab31C0f6459b63fc9b1` | Swaps and liquidity |
| WDOGE | `0xcfB3755b306c85404142cfA5821E2e620140D38d` | Wrapped DOGE |
| KingS | `0x5Aea7428C4C6368eAF5861064d5F7174e76F7a05` | CavFi token, fixed supply of 1B |
| KingFarm | `0x659F4F7fA85D64e32397291C024878634593D38D` | LP farms (owned by KingVote) |
| KingStake | `0xC4fE2e485C9D409972e169e21F41A6eF0EAD8D98` | Single-token staking |
| KingLaunch | `0x818bE6335111B4cCfC7387c71d61a8E1b9adC27e` | Meme launchpad (bonding curve) |
| KingLimit | `0x29470D73A1a4f88Db57BAa248BFE3CA2Ae11687d` | Limit orders |
| KingVote | `0x17F4e4D640A86dB5f70aBE3d5C29Cd1bF6506cf4` | KingS voting on farm weights |
| KingBadges | `0x4cf1D6ecfbf76cb7732d7F2ab96563bB4Bc66719` | Soulbound achievement badges |
| cUSDT / cUSDC | `0xaa275507421879aD761C266b971EAB8f5c6825c0` / `0xA4F301009fB9362f2e1287a40521BA45777fB385` | CavFi test stables (hourly faucet) |

The current list is always in `site/addresses.json`.

## Run it

**Website:** serve `site/` with any static server (`npx serve site`) and open it with MetaMask on DogeOS testnet
(RPC `https://rpc.testnet.dogeos.com`). No build step.

**Contracts:**
```bash
cd contracts
forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 foundry-rs/forge-std --no-git   # only if lib/ is missing
forge test
forge script script/Deploy.s.sol --rpc-url dogeos --broadcast   # needs PRIVATE_KEY in the environment
```

**Bot:** `cd bot && npm install && node cavfi-bot.mjs` (see `bot/README.md`).

## Security

See `contracts/SECURITY.md`: Slither, invariant fuzzing, manual review and known limits. Testnet only; not audited.
