# Saves the bot wallet's private key encrypted for YOUR Windows user (DPAPI).
# Only this Windows account on this PC can decrypt it. Run once:
#   powershell -ExecutionPolicy Bypass -File setup-key.ps1
Set-Location $PSScriptRoot
$s = Read-Host "Bot wallet private key (hidden)" -AsSecureString
if ($s.Length -lt 60) { Write-Host "That does not look like a private key (too short). Nothing saved." -ForegroundColor Red; exit 1 }
$s | ConvertFrom-SecureString | Set-Content -Path "$PSScriptRoot\bot-key.dpapi" -Encoding ASCII
Write-Host "Saved, encrypted, to bot-key.dpapi" -ForegroundColor Green
