// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {KingS} from "../src/KingS.sol";
import {WDOGE} from "../src/WDOGE.sol";
import {KingFactory} from "../src/KingFactory.sol";
import {KingRouter} from "../src/KingRouter.sol";

/// Deploys WDOGE, factory, router, the KingS token, and seeds the KingS/DOGE pool.
/// Env (all optional except PRIVATE_KEY):
///   KINGS_SUPPLY   total KingS supply in whole tokens   (default 1,000,000,000)
///   POOL_KINGS     KingS put into the first pool         (default 100,000)
///   POOL_DOGE_WEI  DOGE put into the first pool, in wei  (default 1 DOGE = 1e18)
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        uint256 supply = vm.envOr("KINGS_SUPPLY", uint256(1_000_000_000)) * 1e18;
        uint256 poolKings = vm.envOr("POOL_KINGS", uint256(100_000)) * 1e18;
        uint256 poolDoge = vm.envOr("POOL_DOGE_WEI", uint256(1 ether));

        require(me.balance > poolDoge, "Not enough test DOGE for pool + gas. Use the faucet first.");

        vm.startBroadcast(pk);
        WDOGE wdoge = new WDOGE();
        KingFactory factory = new KingFactory(me, vm.envOr("FEE_TO", me));
        KingRouter router = new KingRouter(address(factory), address(wdoge));
        KingS kings = new KingS(me, supply);
        kings.approve(address(router), poolKings);
        router.addLiquidityETH{value: poolDoge}(address(kings), poolKings, 0, 0, me, block.timestamp + 1200);
        vm.stopBroadcast();

        address pair = factory.getPair(address(kings), address(wdoge));

        console2.log("WDOGE   ", address(wdoge));
        console2.log("Factory ", address(factory));
        console2.log("Router  ", address(router));
        console2.log("KingS   ", address(kings));
        console2.log("Pair    ", pair);

        string memory o = "deploy";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "wdoge", address(wdoge));
        vm.serializeAddress(o, "factory", address(factory));
        vm.serializeAddress(o, "router", address(router));
        vm.serializeAddress(o, "pair", pair);
        string memory json = vm.serializeAddress(o, "kings", address(kings));
        vm.writeJson(json, "../site/addresses.json");
        console2.log("Saved ../site/addresses.json");
    }
}
