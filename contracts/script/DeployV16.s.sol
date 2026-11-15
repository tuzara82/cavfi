// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingMarkets} from "../src/KingMarkets.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Deploys CavFi Markets (predictions on football, crypto prices and DogeOS events) with the bot as the resolver
/// that creates markets and proposes results (24 h dispute window). Adds "markets" to addresses.json.
contract DeployV16 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        string memory json = AddrBook.read();
        address kings = AddrBook.get(json, "kings");
        address bot = AddrBook.getOr(json, "bot", vm.envOr("BOT_ADDRESS", me));
        vm.startBroadcast(pk);
        KingMarkets m = new KingMarkets(me, IERC20(kings), bot);
        vm.stopBroadcast();
        console2.log("Markets    ", address(m));
        console2.log("Resolver   ", bot);
        AddrBook.write1(json, "markets", address(m));
        console2.log("Updated ../site/addresses.json");
    }
}
