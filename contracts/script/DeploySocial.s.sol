// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingSocial} from "../src/KingSocial.sol";

/// Deploys KingSocial (referrals, token comments, Royal Herald badge) and adds "social" to addresses.json.
/// Env: BOT_ADDRESS  the CavFi bot wallet that awards Royal Herald (default: you)
contract DeploySocial is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        address bot = vm.envOr("BOT_ADDRESS", me);
        string memory json = AddrBook.read();
        vm.startBroadcast(pk);
        KingSocial s = new KingSocial(me, bot);
        vm.stopBroadcast();
        console2.log("Social      ", address(s));
        console2.log("Bot (minter)", bot);
        AddrBook.write1(json, "social", address(s));
        console2.log("Updated ../site/addresses.json");
    }
}
