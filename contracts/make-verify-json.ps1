# Writes Blockscout "standard JSON input" files for every CavFi contract that is not verified yet.
# Run from C:\kingswap\contracts:   powershell -ExecutionPolicy Bypass -File make-verify-json.ps1
# Output: C:\kingswap\contracts\verify-json\<name>-standard.json  (UTF-8 without BOM)
# Compiler for all of them: v0.8.24+commit.e11b9ed9, optimizer on (200 runs), viaIR, evmVersion paris.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$out = Join-Path $PSScriptRoot 'verify-json'
New-Item -ItemType Directory -Force $out | Out-Null
$list = @(
  @('arena',     '0xdeaba4d9ad607779217745Dbd3e4e02b9A6AADf2', 'KingArena'),
  @('names',     '0xe884F5d25c71656Bea48D9A5e0853551f8cbf8E9', 'KingNames'),
  @('gm',        '0x358292433f25b737838CDCe0ce6F638C214640b1', 'KingGM'),
  @('champion',  '0x1C9E2B55Ca8132A754882b42C6c85Fa8Cc1d7300', 'KingChampion'),
  @('limit',     '0x29470D73A1a4f88Db57BAa248BFE3CA2Ae11687d', 'KingLimit'),
  @('cavaliers', '0x8D9C4355F9DCb1653251ed63ca5033045e06aACd', 'KingCavaliers'),
  @('social',    '0x0A1d494C108Cca8C74513db8c6AAE68eB5281228', 'KingSocial'),
  @('dca',       '0xd95FF0515806bA95911080f1Ce62B763C7EA1347', 'KingDCA'),
  @('quests',    '0xfDDcc6F355c93D5De823E857ccbff1b64b90Fc9A', 'KingQuests'),
  @('raffle',    '0x23ae3B9CD19DaC6B8Fff32E169731264b9e0d0eF', 'KingRaffle'),
  @('duel',      '0x714D1a40E4206ebDC7e3c3228a56aE6584f48087', 'KingDuel'),
  @('predict',   '0x1C12E2E279d7776e56900b323828E25C940A21db', 'KingPredict')
)
$utf8 = New-Object Text.UTF8Encoding $false
$lines = @("CavFi contracts - Blockscout standard JSON input", "Chain: DogeOS Chikyu testnet (6281971)", "Compiler: v0.8.24+commit.e11b9ed9, optimizer 200 runs, viaIR true, evmVersion paris", "")
foreach ($c in $list){
  $key, $addr, $name = $c
  Write-Host "$name ..." -NoNewline
  $j = forge verify-contract $addr "src/$name.sol:$name" --show-standard-json-input
  if ($LASTEXITCODE -ne 0 -or -not $j){ Write-Host " FAILED" -ForegroundColor Red; continue }
  $file = Join-Path $out "$key-standard.json"
  [IO.File]::WriteAllText($file, ($j -join "`n"), $utf8)
  $kb = [math]::Round((Get-Item $file).Length / 1KB)
  Write-Host " ok ($kb KB)" -ForegroundColor Green
  $lines += "$name  $addr  ->  $key-standard.json  (contract name: src/$name.sol:$name)"
}
[IO.File]::WriteAllText((Join-Path $out 'README.txt'), ($lines -join "`r`n"), $utf8)
Write-Host "`nDone: $out" -ForegroundColor Cyan
