// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KingRouter} from "../src/KingRouter.sol";
import {KingFactory} from "../src/KingFactory.sol";
import {AddrBook} from "./AddrBook.sol";

/// Lists the official DogeOS faucet tokens on CavFi: creates a pool for each one against
/// CavFi's test USDT (cUSDT, 6 decimals) at a real-world price, using tokens you claimed
/// from https://faucet.testnet.dogeos.com. Tokens you do not hold enough of are skipped;
/// run it again after claiming and it fills in the missing pools (existing ones are topped up).
///
/// Env (all optional):
///   BTC_PRICE  USD per LBTC   (default 82000)
///   ETH_PRICE  USD per WETH   (default 2400)
///   AMT_LBTC   LBTC to add, wei (default 0.05 LBTC)
///   AMT_WETH   WETH to add, wei (default 0.5 WETH)
///   AMT_STABLE USD1/USDC/USDT to add each, wei (default 50)
///   LBTC_ADDR / WETH_ADDR / USD1_ADDR / FUSDC_ADDR / FUSDT_ADDR  override token addresses (local testing)
contract SeedFaucetPools is Script {
    struct T { string key; string sym; address token; uint256 amount; uint256 price; }

    function _tokens() internal view returns (T[] memory ts) {
        ts = new T[](5);
        ts[0] = T("lbtc",  "LBTC", vm.envOr("LBTC_ADDR",  address(0x29789F5A3e4c3113e7165c33A7E3bc592CF6fE0E)), vm.envOr("AMT_LBTC", uint256(0.05 ether)), vm.envOr("BTC_PRICE", uint256(82000)));
        ts[1] = T("weth",  "WETH", vm.envOr("WETH_ADDR",  address(0x1a6094Ac3ca3Fc9F1B4777941a5f4AAc16A72000)), vm.envOr("AMT_WETH", uint256(0.5 ether)),  vm.envOr("ETH_PRICE", uint256(2400)));
        uint256 st = vm.envOr("AMT_STABLE", uint256(50 ether));
        ts[2] = T("usd1",  "USD1", vm.envOr("USD1_ADDR",  address(0x25D5E5375e01Ed39Dc856bDCA5040417fD45eA3F)), st, 1);
        ts[3] = T("fusdc", "USDC", vm.envOr("FUSDC_ADDR", address(0xD19d2Ffb1c284668b7AFe72cddae1BAF3Bc03925)), st, 1);
        ts[4] = T("fusdt", "USDT", vm.envOr("FUSDT_ADDR", address(0xC81800b77D91391Ef03d7868cB81204E753093a9)), st, 1);
    }

    function _seed(T memory t, address me, KingRouter router, KingFactory factory, address cusdt) internal {
        if (IERC20(t.token).balanceOf(me) < t.amount) {
            console2.log("SKIP (claim it from the faucet first):", t.sym);
            return;
        }
        // all faucet tokens have 18 decimals; cUSDT has 6
        uint256 usd6 = t.amount * t.price / 1e12;
        IERC20(t.token).approve(address(router), t.amount);
        router.addLiquidity(t.token, cusdt, t.amount, usd6, 0, 0, me, block.timestamp + 1200);
        console2.log("Pool", t.sym, "/ cUSDT:", factory.getPair(t.token, cusdt));
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        string memory json = AddrBook.read();
        KingRouter router = KingRouter(payable(AddrBook.get(json, "router")));
        KingFactory factory = KingFactory(AddrBook.get(json, "factory"));
        address cusdt = AddrBook.get(json, "usdt");
        T[] memory ts = _tokens();

        vm.startBroadcast(pk);
        IERC20(cusdt).approve(address(router), type(uint256).max);
        for (uint256 i; i < ts.length; i++) _seed(ts[i], me, router, factory, cusdt);
        vm.stopBroadcast();

        string[] memory keys = new string[](5);
        address[] memory vals = new address[](5);
        for (uint256 i; i < ts.length; i++) (keys[i], vals[i]) = (ts[i].key, ts[i].token);
        AddrBook.write(json, keys, vals);
        console2.log("Updated ../site/addresses.json");
    }
}
