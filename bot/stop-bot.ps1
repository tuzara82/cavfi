# Stops the running bot (it starts again at next login). Add -Remove to uninstall the task.
param([switch]$Remove)
Stop-ScheduledTask -TaskName "CavFi Bot" -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -like "*start-bot.ps1*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" | Where-Object { $_.CommandLine -like "*cavfi-bot.mjs*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
if ($Remove) { Unregister-ScheduledTask -TaskName "CavFi Bot" -Confirm:$false -ErrorAction SilentlyContinue; Write-Host "Task removed." }
Write-Host "Bot stopped."
