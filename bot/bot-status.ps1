# Shows whether the bot task is running and the last lines of today's log.
Set-Location $PSScriptRoot
$t = Get-ScheduledTask -TaskName "CavFi Bot" -ErrorAction SilentlyContinue
if ($t) { Write-Host ("Task: " + $t.State) -ForegroundColor Cyan } else { Write-Host "Task: not installed" -ForegroundColor Yellow }
$procs = Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" | Where-Object { $_.CommandLine -like "*cavfi-bot.mjs*" }
Write-Host ("Bot processes: " + @($procs).Count)
$log = Get-ChildItem "$PSScriptRoot\logs\*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
if ($log) { Write-Host ("--- " + $log.Name); Get-Content $log.FullName -Tail 25 -Encoding UTF8 } else { Write-Host "No log yet." }
