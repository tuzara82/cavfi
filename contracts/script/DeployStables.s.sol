// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestStable} from "../src/TestStable.sol";
import {KingRouter} from "../src/KingRouter.sol";
import {KingFactory} from "../src/KingFactory.sol";

/// Adds test USDT and USDC to an existing KingSwap deployment and seeds pools.
/// Reads ../site/addresses.json (written by Deploy.s.sol) and adds "usdt" and "usdc" to it.
///
/// Default pools (implied price: 1 KingS = $0.000002, 1 DOGE = $0.20):
///   USDT / USDC    100,000 / 100,000
///   KingS / USDT   10,000,000 / 20
///   KingS / USDC   10,000,000 / 20
/// Optional env: POOL_DOGE_USDT_WEI  DOGE (in wei) for a DOGE/USDT pool at $0.20 per DOGE (default 0 = skip)
contract DeployStables is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        string memory json = vm.readFile("../site/addresses.json");
        address router = vm.parseJsonAddress(json, ".router");
        address kings = vm.parseJsonAddress(json, ".kings");
        address wdoge = vm.parseJsonAddress(json, ".wdoge");
        address factory = vm.parseJsonAddress(json, ".factory");
        address pair = vm.parseJsonAddress(json, ".pair");

        uint256 dogeForUsdt = vm.envOr("POOL_DOGE_USDT_WEI", uint256(0));
        uint256 kingsNeeded = 20_000_000 ether;
        require(IERC20(kings).balanceOf(me) >= kingsNeeded, "Deployer needs 20,000,000 KingS");

        uint256 dl = block.timestamp + 1200;
        vm.startBroadcast(pk);
        TestStable usdt = new TestStable("Test Tether USD", "USDT", me, 10_000_000 * 1e6);
        TestStable usdc = new TestStable("Test USD Coin", "USDC", me, 10_000_000 * 1e6);
        usdt.approve(router, type(uint256).max);
        usdc.approve(router, type(uint256).max);
        IERC20(kings).approve(router, kingsNeeded);

        KingRouter r = KingRouter(payable(router));
        r.addLiquidity(address(usdt), address(usdc), 100_000e6, 100_000e6, 0, 0, me, dl);
        r.addLiquidity(kings, address(usdt), 10_000_000 ether, 20e6, 0, 0, me, dl);
        r.addLiquidity(kings, address(usdc), 10_000_000 ether, 20e6, 0, 0, me, dl);
        if (dogeForUsdt > 0) {
            // $0.20 per DOGE: USDT (6 dec) = wei * 0.2 / 1e12
            r.addLiquidityETH{value: dogeForUsdt}(address(usdt), dogeForUsdt / 5e12, 0, 0, me, dl);
        }
        vm.stopBroadcast();

        console2.log("USDT    ", address(usdt));
        console2.log("USDC    ", address(usdc));
        console2.log("Pairs   ", KingFactory(factory).allPairsLength());

        string[] memory k = new string[](2);
        address[] memory v = new address[](2);
        (k[0], v[0], k[1], v[1]) = ("usdt", address(usdt), "usdc", address(usdc));
        AddrBook.write(json, k, v);
        console2.log("Updated ../site/addresses.json");
    }
}
