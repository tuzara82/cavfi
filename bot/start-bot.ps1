# Runs the CavFi bot forever: restarts it if it stops, writes a log per day to .\logs
# Started by the "CavFi Bot" scheduled task, or by hand:
#   powershell -ExecutionPolicy Bypass -File start-bot.ps1
Set-Location $PSScriptRoot
$keyFile = Join-Path $PSScriptRoot "bot-key.dpapi"
if (-not (Test-Path $keyFile)) { Write-Host "Run setup-key.ps1 first." -ForegroundColor Red; exit 1 }
$sec = Get-Content $keyFile | ConvertTo-SecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
$env:PRIVATE_KEY = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { $node = Join-Path $env:ProgramFiles "nodejs\node.exe" }
New-Item -ItemType Directory -Force -Path (Join-Path $PSScriptRoot "logs") | Out-Null

while ($true) {
    $log = Join-Path $PSScriptRoot ("logs\bot-" + (Get-Date -Format "yyyy-MM-dd") + ".log")
    Add-Content -Path $log -Value ("=== start " + (Get-Date -Format "s"))
    # cmd keeps the log in plain UTF-8 and catches both output streams
    cmd /c "`"$node`" cavfi-bot.mjs >> `"$log`" 2>&1"
    $code = $LASTEXITCODE
    Add-Content -Path $log -Value ("=== exited with code $code at " + (Get-Date -Format "s") + ", restarting in 20 s")
    if ($code -eq 3) { Add-Content -Path $log -Value "=== another bot is already running; not restarting"; break }
    Start-Sleep -Seconds 20
}
