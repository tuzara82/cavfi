// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingGames} from "../src/KingGames.sol";

/// Deploys CavFi Games (Coin Flip + Dice) with the bot as the house and funds the bankroll
/// (GAMES_FUND, default 50 DOGE). The bot sets the first hash-chain anchor on its next start.
/// Adds "games" to addresses.json.
contract DeployV10 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        string memory json = AddrBook.read();
        address bot = AddrBook.getOr(json, "bot", vm.envOr("BOT_ADDRESS", me));
        uint256 fund = vm.envOr("GAMES_FUND", uint256(50 ether));
        vm.startBroadcast(pk);
        KingGames g = new KingGames(me, bot);
        if (fund > 0) {
            (bool ok,) = address(g).call{value: fund}("");
            require(ok, "fund");
        }
        vm.stopBroadcast();
        console2.log("Games      ", address(g));
        console2.log("House (bot)", bot);
        console2.log("Bankroll   ", fund);
        AddrBook.write1(json, "games", address(g));
        console2.log("Updated ../site/addresses.json");
    }
}
