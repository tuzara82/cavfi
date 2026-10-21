// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KingFarm} from "../src/KingFarm.sol";
import {KingFactory} from "../src/KingFactory.sol";

/// Deploys KingFarm, adds every KingSwap pool with a reward weight and funds it with KingS.
/// Reads ../site/addresses.json and adds "farm" to it.
///
/// Default weights (share of rewards):
///   KingS/DOGE 40 · KingS/USDT 30 · KingS/USDC 20 · DOGE/USDT 10 · USDT/USDC 5
///   any other pool found in the factory: 5
/// Env (optional):
///   FARM_REWARDS  KingS to stream, whole tokens   (default 50,000,000)
///   FARM_DAYS     length of the reward period     (default 30)
contract DeployFarm is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        uint256 rewards = vm.envOr("FARM_REWARDS", uint256(50_000_000)) * 1e18;
        uint256 dur = vm.envOr("FARM_DAYS", uint256(30)) * 1 days;

        string memory json = vm.readFile("../site/addresses.json");
        address factory = vm.parseJsonAddress(json, ".factory");
        address kings = vm.parseJsonAddress(json, ".kings");
        address wdoge = vm.parseJsonAddress(json, ".wdoge");
        address usdt = vm.keyExistsJson(json, ".usdt") ? vm.parseJsonAddress(json, ".usdt") : address(0);
        address usdc = vm.keyExistsJson(json, ".usdc") ? vm.parseJsonAddress(json, ".usdc") : address(0);
        require(IERC20(kings).balanceOf(me) >= rewards, "Not enough KingS for FARM_REWARDS");

        KingFactory f = KingFactory(factory);
        uint256 n = f.allPairsLength();

        vm.startBroadcast(pk);
        KingFarm farm = new KingFarm(IERC20(kings), me);
        for (uint256 i; i < n; i++) {
            address pair = f.allPairs(i);
            uint256 w = 5;
            if (pair == f.getPair(kings, wdoge)) w = 40;
            else if (usdt != address(0) && pair == f.getPair(kings, usdt)) w = 30;
            else if (usdc != address(0) && pair == f.getPair(kings, usdc)) w = 20;
            else if (usdt != address(0) && pair == f.getPair(wdoge, usdt)) w = 10;
            farm.add(w, IERC20(pair));
        }
        IERC20(kings).approve(address(farm), rewards);
        farm.fund(rewards, dur);
        vm.stopBroadcast();

        console2.log("Farm        ", address(farm));
        console2.log("Pools       ", farm.poolLength());
        console2.log("Rewards     ", rewards / 1e18, "KingS");
        console2.log("Days        ", dur / 1 days);
        console2.log("KingS/day   ", farm.rewardPerSecond() * 1 days / 1e18);

        AddrBook.write1(json, "farm", address(farm));
        console2.log("Updated ../site/addresses.json");
    }
}
