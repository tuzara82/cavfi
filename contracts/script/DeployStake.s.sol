// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KingStake} from "../src/KingStake.sol";

/// Deploys KingStake (single-token staking), adds KingS, DOGE (WDOGE), USDT, USDC and funds it.
/// Reads ../site/addresses.json and adds "stake" to it.
///
/// Default weights: KingS 40 · DOGE 30 · USDT 15 · USDC 15
/// Env (optional):
///   STAKE_REWARDS  KingS to stream, whole tokens   (default 20,000,000)
///   STAKE_DAYS     length of the reward period     (default 30)
contract DeployStake is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        uint256 rewards = vm.envOr("STAKE_REWARDS", uint256(20_000_000)) * 1e18;
        uint256 dur = vm.envOr("STAKE_DAYS", uint256(30)) * 1 days;

        string memory json = vm.readFile("../site/addresses.json");
        address kings = vm.parseJsonAddress(json, ".kings");
        address wdoge = vm.parseJsonAddress(json, ".wdoge");
        address usdt = vm.keyExistsJson(json, ".usdt") ? vm.parseJsonAddress(json, ".usdt") : address(0);
        address usdc = vm.keyExistsJson(json, ".usdc") ? vm.parseJsonAddress(json, ".usdc") : address(0);
        require(IERC20(kings).balanceOf(me) >= rewards, "Not enough KingS for STAKE_REWARDS");

        vm.startBroadcast(pk);
        KingStake st = new KingStake(IERC20(kings), wdoge, me);
        st.add(40, IERC20(kings));
        st.add(30, IERC20(wdoge));
        if (usdt != address(0)) st.add(15, IERC20(usdt));
        if (usdc != address(0)) st.add(15, IERC20(usdc));
        IERC20(kings).approve(address(st), rewards);
        st.fund(rewards, dur);
        vm.stopBroadcast();

        console2.log("Stake       ", address(st));
        console2.log("Pools       ", st.poolLength());
        console2.log("Rewards     ", rewards / 1e18, "KingS");
        console2.log("Days        ", dur / 1 days);
        console2.log("KingS/day   ", st.rewardPerSecond() * 1 days / 1e18);

        AddrBook.write1(json, "stake", address(st));
        console2.log("Updated ../site/addresses.json");
    }
}
