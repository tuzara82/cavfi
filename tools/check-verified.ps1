# Checks every contract in site\addresses.json on Sourcify and on L2Scan (the DogeOS explorer).
#   powershell -ExecutionPolicy Bypass -File C:\kingswap\tools\check-verified.ps1
# Add -Fix to verify the ones L2Scan is missing (forge, from C:\kingswap\contracts).
param([switch]$Fix)
$ErrorActionPreference = "Continue"
$root = Split-Path $PSScriptRoot -Parent
$a = Get-Content (Join-Path $root "site\addresses.json") -Raw | ConvertFrom-Json
$src = @{
  arena="KingArena"; badges="KingBadges"; callouts="KingCallouts"; champion="KingChampion"; dca="KingDCA"
  duel="KingDuel"; events="KingEventBadges"; factory="KingFactory"; farm="KingFarm"; gm="KingGM"
  games="KingGames2"; gamesV1="KingGames"; guess="KingGuess3"; guessV2="KingGuess2"; guessV1="KingGuess"
  hunt="KingHunt"; kings="KingS"; launch="KingLaunch"; limit="KingLimit"; names="KingNames"; nft="KingCavaliers"
  predict="KingPredict3"; predictV2="KingPredict2"; predictV1="KingPredict"; quests="KingQuests"; raffle="KingRaffle"
  router="KingRouter"; social="KingSocial"; spin="KingSpin"; stake="KingStake"; vote="KingVote"; wdoge="WDOGE"
}
$rpc = "https://rpc.testnet.dogeos.com"
$scan = "https://l2scan.testnet.dogeos.com"
$missing = @()
$rows = foreach ($p in $a.PSObject.Properties) {
  $k = $p.Name; $v = "$($p.Value)"
  if ($k -eq "bot" -or -not $v.StartsWith("0x")) { continue }
  $sf = "no"; $ls = "?"
  try { $sf = (Invoke-RestMethod "https://sourcify.dev/server/v2/contract/6281971/$v" -TimeoutSec 20).match } catch { $sf = "no" }
  try {
    $j = Invoke-RestMethod "$scan/api/v2/smart-contracts/$v" -TimeoutSec 20
    $ls = if ($j.is_verified) { "yes" } elseif ($j.is_partially_verified) { "partial" } else { "NO" }
  } catch { $ls = "NO" }
  if ($ls -ne "yes") { $missing += $k }
  [pscustomobject]@{ Name = $k; Address = $v; Sourcify = $sf; L2Scan = $ls }
}
$rows | Sort-Object L2Scan, Name | Format-Table -AutoSize
Write-Host ("L2Scan verified: {0} of {1}" -f ($rows | Where-Object L2Scan -eq "yes").Count, $rows.Count)
if ($missing.Count -eq 0) { exit }
Write-Host ("Missing on L2Scan: " + ($missing -join ", ")) -ForegroundColor Yellow
if (-not $Fix) { Write-Host "Run again with -Fix to verify them."; exit }
Push-Location (Join-Path $root "contracts")
foreach ($k in $missing) {
  if (-not $src.ContainsKey($k)) { Write-Host "skip $k (not one of our sources: a pair or a test token)" -ForegroundColor DarkGray; continue }
  $c = $src[$k]; $addr = $a.$k
  Write-Host "== $k ($c) $addr" -ForegroundColor Cyan
  forge verify-contract $addr "src/$c.sol:$c" --chain-id 6281971 --verifier blockscout --verifier-url "$scan/api/" --rpc-url $rpc --guess-constructor-args --watch
}
Pop-Location
