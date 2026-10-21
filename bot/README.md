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
