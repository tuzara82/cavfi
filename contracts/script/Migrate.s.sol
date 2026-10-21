// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KingFactory} from "../src/KingFactory.sol";
import {KingRouter} from "../src/KingRouter.sol";

interface IOldFactory {
    function allPairsLength() external view returns (uint256);
    function allPairs(uint256) external view returns (address);
}

interface IOldPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IOldRouter {
    function removeLiquidity(address, address, uint256, uint256, uint256, address, uint256) external returns (uint256, uint256);
}

/// Moves your liquidity from the current KingSwap pools into new pools that have the
/// 0.05% protocol fee switch. Tokens (KingS, WDOGE, USDT, USDC) stay the same.
///
/// 1. Deploys a new KingFactory (fee to FEE_TO, default: you) and a new KingRouter.
/// 2. For every old pool where you hold LP tokens: withdraws 100% and deposits the
///    exact same amounts into the matching new pool, so every price is unchanged.
/// 3. Rewrites ../site/addresses.json with the new factory and router and keeps the
///    old ones as legacyFactory / legacyRouter.
///
/// Only your own LP is moved. A tiny dust amount (1000 wei of LP, locked forever by
/// design) stays in each old pool.
contract Migrate is Script {
    struct Moved { address t0; address t1; uint256 a0; uint256 a1; }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        address feeTo = vm.envOr("FEE_TO", me);

        string memory json = vm.readFile("../site/addresses.json");
        // Safe to run again: if a migration already happened, keep the new factory/router
        // and only move whatever LP is still left in the legacy pools.
        bool again = vm.keyExistsJson(json, ".legacyFactory");
        address oldRouter = vm.parseJsonAddress(json, again ? ".legacyRouter" : ".router");
        address oldFactory = vm.parseJsonAddress(json, again ? ".legacyFactory" : ".factory");
        address wdoge = vm.parseJsonAddress(json, ".wdoge");
        address kings = vm.parseJsonAddress(json, ".kings");

        uint256 n = IOldFactory(oldFactory).allPairsLength();
        uint256 dl = block.timestamp + 1800;

        vm.startBroadcast(pk);
        KingFactory factory = again
            ? KingFactory(vm.parseJsonAddress(json, ".factory"))
            : new KingFactory(me, feeTo);
        KingRouter router = again
            ? KingRouter(payable(vm.parseJsonAddress(json, ".router")))
            : new KingRouter(address(factory), wdoge);

        Moved[] memory moved = new Moved[](n);
        uint256 count;
        for (uint256 i; i < n; i++) {
            IOldPair p = IOldPair(IOldFactory(oldFactory).allPairs(i));
            uint256 lp = p.balanceOf(me);
            if (lp == 0) continue;
            address t0 = p.token0();
            address t1 = p.token1();
            p.approve(oldRouter, lp);
            (uint256 a0, uint256 a1) = IOldRouter(oldRouter).removeLiquidity(t0, t1, lp, 0, 0, me, dl);
            IERC20(t0).approve(address(router), a0);
            IERC20(t1).approve(address(router), a1);
            // new pool empty -> exact amounts; new pool already funded -> keep its price
            bool fresh = factory.getPair(t0, t1) == address(0);
            router.addLiquidity(t0, t1, a0, a1, fresh ? a0 : 0, fresh ? a1 : 0, me, dl);
            moved[count++] = Moved(t0, t1, a0, a1);
        }
        vm.stopBroadcast();

        console2.log("New factory ", address(factory));
        console2.log("New router  ", address(router));
        console2.log("Fee to      ", factory.feeTo());
        if (again) console2.log("(re-run: moved remaining LP from the legacy pools)");
        console2.log("Pools moved ", count);
        for (uint256 i; i < count; i++) {
            console2.log("  pool", factory.getPair(moved[i].t0, moved[i].t1));
            console2.log("    amounts", moved[i].a0, moved[i].a1);
        }

        _save(json, address(factory), address(router), factory.getPair(kings, wdoge), oldFactory, oldRouter);
        console2.log("Updated ../site/addresses.json");
    }

    function _save(string memory json, address factory, address router, address pair, address oldFactory, address oldRouter) internal {
        string[] memory k = new string[](5);
        address[] memory v = new address[](5);
        (k[0], v[0]) = ("factory", factory);
        (k[1], v[1]) = ("router", router);
        (k[2], v[2]) = ("pair", pair);
        (k[3], v[3]) = ("legacyFactory", oldFactory);
        (k[4], v[4]) = ("legacyRouter", oldRouter);
        AddrBook.write(json, k, v);
    }
}
