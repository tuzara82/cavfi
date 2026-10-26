# Verifies CavFi contracts on Sourcify (DogeOS testnet, chain 6281971). L2Scan reads Sourcify ("Import from
# Sourcify" on its Verify Contract page) and many explorers show Sourcify-verified code too.
# Run from C:\kingswap\contracts:   powershell -ExecutionPolicy Bypass -File verify-sourcify.ps1
# Only one contract:                 powershell -ExecutionPolicy Bypass -File verify-sourcify.ps1 arena
param([string]$Only = '')
Set-Location $PSScriptRoot
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
  @('predict',   '0x1C12E2E279d7776e56900b323828E25C940A21db', 'KingPredict'),
  @('guess',     '0xDC7F5E5E39f7c1731a235a7605A1fD35D6302ae2', 'KingGuess')
)
foreach ($c in $list){
  $key, $addr, $name = $c
  if ($Only -and $Only -ne $key){ continue }
  Write-Host "`n=== $name $addr" -ForegroundColor Cyan
  forge verify-contract $addr "src/$name.sol:$name" --chain-id 6281971 --verifier sourcify --watch
}
