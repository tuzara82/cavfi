# Makes the bot start by itself every time you log in to Windows (hidden window).
#   powershell -ExecutionPolicy Bypass -File install-task.ps1
Set-Location $PSScriptRoot
if (-not (Test-Path "$PSScriptRoot\bot-key.dpapi")) { Write-Host "Run setup-key.ps1 first." -ForegroundColor Red; exit 1 }
if (-not (Test-Path "$PSScriptRoot\node_modules")) { Write-Host "Run npm install first." -ForegroundColor Red; exit 1 }
$name = "CavFi Bot"
$user = "$env:USERDOMAIN\$env:USERNAME"
$arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSScriptRoot\start-bot.ps1`""
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description "CavFi keeper: limit orders, pool fixes, Telegram alerts" -Force | Out-Null
Start-ScheduledTask -TaskName $name
Start-Sleep -Seconds 3
Write-Host "Installed and started '$name'. It now starts at every login." -ForegroundColor Green
Write-Host "Check it:  powershell -ExecutionPolicy Bypass -File bot-status.ps1"
