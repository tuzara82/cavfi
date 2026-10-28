// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingLaunch} from "../src/KingLaunch.sol";
import {KingCallouts} from "../src/KingCallouts.sol";

/// Deploys CavFi Callouts (call a Launchpad token at today's price) and adds "callouts" to ../site/addresses.json.
contract DeployV7 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        string memory json = AddrBook.read();
        address launch = AddrBook.get(json, "launch");
        vm.startBroadcast(pk);
        KingCallouts c = new KingCallouts(KingLaunch(payable(launch)));
        vm.stopBroadcast();
        console2.log("Callouts    ", address(c));
        AddrBook.write1(json, "callouts", address(c));
        console2.log("Updated ../site/addresses.json");
    }
}
