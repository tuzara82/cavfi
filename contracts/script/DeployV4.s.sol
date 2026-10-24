// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingDuel} from "../src/KingDuel.sol";
import {KingPredict} from "../src/KingPredict.sol";

/// Deploys Arena duels and CavFi Predict (DOGE price markets, the CavFi bot as price oracle),
/// and adds "duel" and "predict" to addresses.json.
contract DeployV4 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        string memory json = AddrBook.read();
        address arena = AddrBook.get(json, "arena");
        address kings = AddrBook.get(json, "kings");
        address bot = AddrBook.getOr(json, "bot", vm.envOr("BOT_ADDRESS", me));

        vm.startBroadcast(pk);
        KingDuel d = new KingDuel(arena, IERC20(kings));
        KingPredict p = new KingPredict(me, IERC20(kings), bot);
        vm.stopBroadcast();

        console2.log("Duel        ", address(d));
        console2.log("Predict     ", address(p));
        console2.log("Oracle (bot)", bot);
        string[] memory k = new string[](2);
        address[] memory v = new address[](2);
        (k[0], v[0]) = ("duel", address(d));
        (k[1], v[1]) = ("predict", address(p));
        AddrBook.write(json, k, v);
        console2.log("Updated ../site/addresses.json");
    }
}
