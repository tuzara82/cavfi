# CavFi bot

One small program that runs on your PC next to the site:

1. **Fills limit orders** placed on cavfi.com as soon as the pools pay the asked price. The bot earns the 0.1% tip.
2. **Fixes mispriced pools** with small trades from its own wallet, only when two other routes agree on the market price.
3. **Posts to Telegram**: new launches, graduations, big swaps, filled orders and every fix it makes.

## Setup (once)

```powershell
cd C:\kingswap\bot
npm install
copy .env.example .env
notepad .env
```

In `.env` fill in `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` (or leave them empty to skip Telegram).
Leave `PRIVATE_KEY` empty: the bot asks for it hidden when it starts.

## Run

```powershell
cd C:\kingswap\bot
node cavfi-bot.mjs
```

Stop with Ctrl+C. `node cavfi-bot.mjs --once` does a single round. `DRY_RUN=1` in `.env` only logs.

Use a separate test wallet for the bot with a few DOGE for gas and some tokens for fixing pools.
Never use a wallet with real funds.

## Run in the background (starts with Windows)

```powershell
cd C:\kingswap\bot
powershell -ExecutionPolicy Bypass -File setup-key.ps1      # once: saves the key encrypted for your Windows user
powershell -ExecutionPolicy Bypass -File install-task.ps1   # once: starts now and at every login
```

| What | Command |
|---|---|
| Is it running? Last log lines | `powershell -ExecutionPolicy Bypass -File bot-status.ps1` |
| Stop it (starts again at next login) | `powershell -ExecutionPolicy Bypass -File stop-bot.ps1` |
| Remove the autostart | `powershell -ExecutionPolicy Bypass -File stop-bot.ps1 -Remove` |
| Start it again now | `Start-ScheduledTask -TaskName "CavFi Bot"` |

Logs are in `logs\bot-YYYY-MM-DD.log`. Only one bot runs at a time: a second copy exits right away.
The PC must be on and not asleep for the bot to work (Settings → System → Power → Sleep: Never, when plugged in).

## CavFi Markets (football, NBA, crypto prices, DogeOS events)

The bot is the resolver of CavFi Markets (`markets` in `site/addresses.json`). Every 10 minutes it:

- opens markets for football (1 / X / 2 after 90 minutes) and NBA games starting in the next 48 hours, from ESPN's public scoreboard (at most `MARKETS_DAILY_MAX` = 8 a day, `MARKETS_LEAGUE_MAX` = 3 per league);
- keeps one "above the line on Friday 20:00 UTC" market open for each of `MARKETS_COINS` (BTC, ETH, DOGE), priced from Coinbase (Binance as a fallback);
- opens "Will the Fat Cat fall before the raid ends?" for the current raid;
- puts `MARKETS_SEED` (500) KingS on every outcome of a new market;
- after each event proposes the result with its source; after the 24 h dispute window it finalizes it.

Your own questions, and rulings on disputed results, go through `market.mjs` with the owner (deployer) key:

```powershell
$s = Read-Host "Private key (deployer)" -AsSecureString
$env:PRIVATE_KEY = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
node market.mjs list
node market.mjs create dogeos "Will DogeOS post Chapter 6 by Nov 22?" "Yes,No" 2026-11-21T18:00Z 2026-11-22T20:00Z "YES if @DogeOS posts Chapter 6 of The Grand Heist on X before Nov 22 20:00 UTC."
node market.mjs propose 12 0 "https://x.com/DogeOS/status/..."
node market.mjs rule 12 1
Remove-Item Env:PRIVATE_KEY; Remove-Variable s
```
