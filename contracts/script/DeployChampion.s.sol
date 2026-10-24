// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingChampion} from "../src/KingChampion.sol";

/// Deploys the Arena Champion badge (soulbound, claimed by winners themselves) and adds "champion" to addresses.json.
contract DeployChampion is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        string memory json = AddrBook.read();
        address arena = AddrBook.get(json, "arena");
        vm.startBroadcast(pk);
        KingChampion c = new KingChampion(arena);
        vm.stopBroadcast();
        console2.log("Champion    ", address(c));
        console2.log("Arena       ", arena);
        AddrBook.write1(json, "champion", address(c));
        console2.log("Updated ../site/addresses.json");
    }
}
