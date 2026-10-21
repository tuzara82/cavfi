// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingBadges} from "../src/KingBadges.sol";

/// Deploys the Royal Court badges (soulbound NFTs) and adds "badges" to ../site/addresses.json.
/// Env: BOT_ADDRESS  the CavFi bot wallet that may award "Royal Swapper" and "Top Ten" (default: you)
contract DeployBadges is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        address bot = vm.envOr("BOT_ADDRESS", me);
        string memory json = AddrBook.read();
        vm.startBroadcast(pk);
        KingBadges b = new KingBadges(me, bot);
        b.setSources(
            AddrBook.getOr(json, "launch", address(0)), AddrBook.getOr(json, "limit", address(0)),
            AddrBook.getOr(json, "farm", address(0)), AddrBook.getOr(json, "stake", address(0)),
            AddrBook.get(json, "factory"), AddrBook.getOr(json, "vote", address(0)));
        vm.stopBroadcast();
        console2.log("Badges      ", address(b));
        console2.log("Bot (minter)", bot);
        AddrBook.write1(json, "badges", address(b));
        console2.log("Updated ../site/addresses.json");
    }
}
