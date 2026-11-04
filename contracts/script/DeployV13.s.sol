// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingSpin} from "../src/KingSpin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Deploys the CavFi Royal Spin (one free spin a day per wallet, KingS prizes) with the bot as the house and
/// funds it with SPIN_FUND KingS from the deployer (default 1,000,000). Adds "spin" to addresses.json.
contract DeployV13 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        string memory json = AddrBook.read();
        address bot = AddrBook.getOr(json, "bot", vm.envOr("BOT_ADDRESS", me));
        address kings = AddrBook.get(json, "kings");
        uint256 fund = vm.envOr("SPIN_FUND", uint256(1_000_000 ether));
        vm.startBroadcast(pk);
        KingSpin s = new KingSpin(me, bot, IERC20(kings));
        if (fund > 0) {
            IERC20(kings).approve(address(s), fund);
            s.fund(fund);
        }
        vm.stopBroadcast();
        console2.log("Royal Spin ", address(s));
        console2.log("House (bot)", bot);
        console2.log("Prize fund ", fund);
        AddrBook.write1(json, "spin", address(s));
        console2.log("Updated ../site/addresses.json");
    }
}
