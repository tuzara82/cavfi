// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingArena} from "../src/KingArena.sol";
import {KingLaunch} from "../src/KingLaunch.sol";

interface IPairFactory {
    function getPair(address, address) external view returns (address);
}

/// Sets the tokens for the NEXT Arena round: the core tokens (KingS, USDT) plus every graduated
/// launchpad meme whose CavFi pool holds at least ARENA_MIN_DOGE WDOGE, deepest pools first,
/// up to 8 tokens in total. Thin pools are left out on purpose: a pool with little DOGE in it
/// is cheap to push around, which would make the round unfair.
/// The running round is not touched; the new list applies from the next round.
///
/// Dry run (shows the list, sends nothing):
///   forge script script/SetArenaTokens.s.sol:SetArenaTokens --rpc-url dogeos
/// Send it (arena owner key):
///   forge script script/SetArenaTokens.s.sol:SetArenaTokens --rpc-url dogeos --broadcast --private-key $env:PRIVATE_KEY
/// Env (optional):
///   ARENA_CORE      comma-separated tokens always included (default: kings,usdt from addresses.json)
///   ARENA_MIN_DOGE  minimum WDOGE in a meme's pool, in wei (default 25 DOGE)
contract SetArenaTokens is Script {
    uint256 private constant MAX = 8;

    function run() external {
        string memory json = AddrBook.read();
        KingArena arena = KingArena(AddrBook.get(json, "arena"));
        KingLaunch launch = KingLaunch(payable(AddrBook.get(json, "launch")));
        address wdoge = AddrBook.get(json, "wdoge");
        IPairFactory factory = IPairFactory(AddrBook.get(json, "factory"));

        address[] memory defCore = new address[](2);
        defCore[0] = AddrBook.get(json, "kings");
        defCore[1] = AddrBook.get(json, "usdt");
        address[] memory core = vm.envOr("ARENA_CORE", ",", defCore);
        uint256 minDoge = vm.envOr("ARENA_MIN_DOGE", uint256(25 ether));

        // graduated memes with enough DOGE in their pool
        uint256 n = launch.count();
        address[] memory cand = new address[](n);
        uint256[] memory depth = new uint256[](n);
        uint256 c;
        for (uint256 i; i < n; i++) {
            address t = launch.tokens(i);
            KingLaunch.Launch memory L = launch.info(t);
            if (!L.graduated) continue;
            address pair = factory.getPair(t, wdoge);
            if (pair == address(0)) continue;
            uint256 d = IERC20(wdoge).balanceOf(pair);
            bool isCore;
            for (uint256 j; j < core.length; j++) if (core[j] == t) isCore = true;
            if (isCore) continue;
            console2.log(string.concat(L.symbol, "  pool WDOGE (wei):"), d);
            if (d < minDoge) {
                console2.log("   -> skipped, pool too thin");
                continue;
            }
            cand[c] = t;
            depth[c] = d;
            c++;
        }
        // deepest first (tiny list, simple sort)
        for (uint256 i; i < c; i++) {
            for (uint256 j = i + 1; j < c; j++) {
                if (depth[j] > depth[i]) {
                    (depth[i], depth[j]) = (depth[j], depth[i]);
                    (cand[i], cand[j]) = (cand[j], cand[i]);
                }
            }
        }
        uint256 total = core.length + c;
        if (total > MAX) total = MAX;
        address[] memory list = new address[](total);
        for (uint256 i; i < total; i++) list[i] = i < core.length ? core[i] : cand[i - core.length];
        require(total >= 2, "SetArenaTokens: need at least 2 tokens");

        console2.log("Next round tokens:", total);
        for (uint256 i; i < total; i++) console2.log("  ", list[i]);

        vm.startBroadcast();
        arena.setTokens(list);
        vm.stopBroadcast();
    }
}
