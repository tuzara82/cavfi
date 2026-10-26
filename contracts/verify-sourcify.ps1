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
  @('guess',     '0xDC7F5E5E39f7c1731a235a7605A1fD35D6302ae2', 'KingGuess'),
  @('router',    '0x736C94259f16437C0cDbBab31C0f6459b63fc9b1', 'KingRouter'),
  @('factory',   '0xf040D9D599414211079b8654108952c1f7A4E7F0', 'KingFactory'),
  @('kings',     '0x5Aea7428C4C6368eAF5861064d5F7174e76F7a05', 'KingS'),
  @('launch',    '0x818bE6335111B4cCfC7387c71d61a8E1b9adC27e', 'KingLaunch'),
  @('badges',    '0x4cf1D6ecfbf76cb7732d7F2ab96563bB4Bc66719', 'KingBadges'),
  @('farm',      '0x659F4F7fA85D64e32397291C024878634593D38D', 'KingFarm'),
  @('stake',     '0xC4fE2e485C9D409972e169e21F41A6eF0EAD8D98', 'KingStake'),
  @('vote',      '0x17F4e4D640A86dB5f70aBE3d5C29Cd1bF6506cf4', 'KingVote'),
  @('wdoge',     '0xcfB3755b306c85404142cfA5821E2e620140D38d', 'WDOGE'),
  @('usdt',      '0xaa275507421879aD761C266b971EAB8f5c6825c0', 'TestStable'),
  @('usdc',      '0xA4F301009fB9362f2e1287a40521BA45777fB385', 'TestStable')
)
foreach ($c in $list){
  $key, $addr, $name = $c
  if ($Only -and $Only -ne $key){ continue }
  Write-Host "`n=== $name $addr" -ForegroundColor Cyan
  forge verify-contract $addr "src/$name.sol:$name" --chain-id 6281971 --verifier sourcify --watch
}
