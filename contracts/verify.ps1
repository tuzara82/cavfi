# KingSwap - verify all contracts on the DogeOS testnet Blockscout explorer
# Run from C:\kingswap\contracts:
#   powershell -ExecutionPolicy Bypass -File verify.ps1

Set-Location $PSScriptRoot
$rpc = "dogeos"
$a = Get-Content ..\site\addresses.json -Raw | ConvertFrom-Json
$run = Get-Content "broadcast\Deploy.s.sol\6281971\run-latest.json" -Raw | ConvertFrom-Json
$deployer = $run.transactions[0].transaction.from
Write-Host "Deployer: $deployer"

$common = @("--verifier", "blockscout",
            "--verifier-url", "https://blockscout.testnet.dogeos.com/api/",
            "--chain", "6281971", "--watch")
$results = @()

function Verify([string]$addr, [string]$id, [string]$ctorArgs) {
    Write-Host ""
    Write-Host "=== $id  $addr ===" -ForegroundColor Cyan
    $fa = @("verify-contract", $addr, $id) + $common
    if ($ctorArgs) { $fa += @("--constructor-args", $ctorArgs) }
    & forge @fa
    $ok = $LASTEXITCODE -eq 0
    $script:results += [pscustomobject]@{ Contract = $id.Split(':')[1]; Address = $addr; Verified = $ok }
}

# constructor arguments
$routerArgs = cast abi-encode "constructor(address,address)" $a.factory $a.wdoge
$supply     = ((cast call $a.kings "totalSupply()(uint256)" --rpc-url $rpc) -split ' ')[0]
$kingsArgs  = cast abi-encode "constructor(address,uint256)" $deployer $supply

Verify $a.wdoge   "src/WDOGE.sol:WDOGE"             ""
$setter  = (cast call $a.factory "feeToSetter()(address)" --rpc-url $rpc).Trim()
$feeTo   = (cast call $a.factory "feeTo()(address)" --rpc-url $rpc).Trim()
$factoryArgs = cast abi-encode "constructor(address,address)" $setter $feeTo
Verify $a.factory "src/KingFactory.sol:KingFactory" $factoryArgs
Verify $a.router  "src/KingRouter.sol:KingRouter"   $routerArgs
Verify $a.kings   "src/KingS.sol:KingS"             $kingsArgs

if ($a.usdt) {
    $usdtArgs = cast abi-encode "constructor(string,string,address,uint256)" "Test Tether USD" "USDT" $deployer 10000000000000
    Verify $a.usdt "src/TestStable.sol:TestStable" $usdtArgs
}
if ($a.usdc) {
    $usdcArgs = cast abi-encode "constructor(string,string,address,uint256)" "Test USD Coin" "USDC" $deployer 10000000000000
    Verify $a.usdc "src/TestStable.sol:TestStable" $usdcArgs
}

if ($a.farm) {
    $farmOwner = (cast call $a.farm "owner()(address)" --rpc-url $rpc).Trim()
    $farmArgs  = cast abi-encode "constructor(address,address)" $a.kings $farmOwner
    Verify $a.farm "src/KingFarm.sol:KingFarm" $farmArgs
}

if ($a.stake) {
    $stakeOwner = (cast call $a.stake "owner()(address)" --rpc-url $rpc).Trim()
    $stakeArgs  = cast abi-encode "constructor(address,address,address)" $a.kings $a.wdoge $stakeOwner
    Verify $a.stake "src/KingStake.sol:KingStake" $stakeArgs
}

if ($a.social) {
    $sRun  = Get-Content "broadcast\DeploySocial.s.sol\6281971\run-latest.json" -Raw | ConvertFrom-Json
    $sCtor = $sRun.transactions[0].arguments
    $sArgs = cast abi-encode "constructor(address,address)" $sCtor[0] $sCtor[1]
    Verify $a.social "src/KingSocial.sol:KingSocial" $sArgs
}

if ($a.badges) {
    $bRun   = Get-Content "broadcast\DeployBadges.s.sol\6281971\run-latest.json" -Raw | ConvertFrom-Json
    $bCtor  = $bRun.transactions[0].arguments
    $bArgs  = cast abi-encode "constructor(address,address)" $bCtor[0] $bCtor[1]
    Verify $a.badges "src/KingBadges.sol:KingBadges" $bArgs
}

if ($a.vote) {
    $voteOwner = (cast call $a.vote "owner()(address)" --rpc-url $rpc).Trim()
    $voteBase  = ((cast call $a.vote "baseAlloc()(uint256)" --rpc-url $rpc) -split ' ')[0]
    $voteArgs  = cast abi-encode "constructor(address,address,address,uint256)" $a.kings $a.farm $voteOwner $voteBase
    Verify $a.vote "src/KingVote.sol:KingVote" $voteArgs
}

if ($a.limit) {
    $limArgs = cast abi-encode "constructor(address,address)" $a.router $a.wdoge
    Verify $a.limit "src/KingLimit.sol:KingLimit" $limArgs
}

if ($a.launch) {
    $lpOwner  = (cast call $a.launch "owner()(address)" --rpc-url $rpc).Trim()
    $lpFeeTo  = (cast call $a.launch "feeTo()(address)" --rpc-url $rpc).Trim()
    $lpHash   = (cast call $a.launch "pairInitCodeHash()(bytes32)" --rpc-url $rpc).Trim()
    $deployTx = Get-Content "broadcast\DeployLaunch.s.sol\6281971\run-latest.json" -Raw | ConvertFrom-Json
    $ctor     = $deployTx.transactions[0].arguments
    $lpArgs   = cast abi-encode "constructor(address,address,bytes32,address,address,uint256,uint256)" $a.factory $a.wdoge $lpHash $lpOwner $ctor[4] $ctor[5] $ctor[6]
    Verify $a.launch "src/KingLaunch.sol:KingLaunch" $lpArgs
    $m = [int](((cast call $a.launch "count()(uint256)" --rpc-url $rpc) -split ' ')[0])
    for ($i = 0; $i -lt $m; $i++) {
        $t   = (cast call $a.launch "tokens(uint256)(address)" $i --rpc-url $rpc).Trim()
        $nm  = (cast call $t "name()(string)" --rpc-url $rpc).Trim().Trim('"')
        $sy  = (cast call $t "symbol()(string)" --rpc-url $rpc).Trim().Trim('"')
        $tArgs = cast abi-encode "constructor(string,string)" $nm $sy
        Verify $t "src/MemeToken.sol:MemeToken" $tArgs
    }
}

$n = [int](((cast call $a.factory "allPairsLength()(uint256)" --rpc-url $rpc) -split ' ')[0])
for ($i = 0; $i -lt $n; $i++) {
    $p = (cast call $a.factory "allPairs(uint256)(address)" $i --rpc-url $rpc).Trim()
    Verify $p "src/KingPair.sol:KingPair" ""
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize
