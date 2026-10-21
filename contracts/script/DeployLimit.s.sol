// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingLimit} from "../src/KingLimit.sol";

/// Deploys CavFi limit orders (KingLimit) and adds "limit" to ../site/addresses.json.
contract DeployLimit is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        string memory json = AddrBook.read();
        address router = AddrBook.get(json, "router");
        address wdoge = AddrBook.get(json, "wdoge");
        vm.startBroadcast(pk);
        KingLimit lim = new KingLimit(router, wdoge);
        vm.stopBroadcast();
        console2.log("Limit orders", address(lim));
        AddrBook.write1(json, "limit", address(lim));
        console2.log("Updated ../site/addresses.json");
    }
}
