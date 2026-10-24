// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingNames} from "../src/KingNames.sol";
import {KingGM} from "../src/KingGM.sol";

/// Deploys CavFi Names (.cav) and GM/GN, and adds "names" and "gm" to addresses.json.
/// Env (optional): NAME_P3 / NAME_P4 / NAME_P5 prices in wei of DOGE (default 10 / 5 / 1 DOGE)
contract DeployNamesGM is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        string memory json = AddrBook.read();
        uint256 p3 = vm.envOr("NAME_P3", uint256(10 ether));
        uint256 p4 = vm.envOr("NAME_P4", uint256(5 ether));
        uint256 p5 = vm.envOr("NAME_P5", uint256(1 ether));
        vm.startBroadcast(pk);
        KingNames n = new KingNames(me, p3, p4, p5);
        KingGM g = new KingGM();
        vm.stopBroadcast();
        console2.log("Names       ", address(n));
        console2.log("GM          ", address(g));
        string[] memory k = new string[](2);
        address[] memory v = new address[](2);
        (k[0], v[0]) = ("names", address(n));
        (k[1], v[1]) = ("gm", address(g));
        AddrBook.write(json, k, v);
        console2.log("Updated ../site/addresses.json");
    }
}
