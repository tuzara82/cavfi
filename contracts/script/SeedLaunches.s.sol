// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";

interface ILaunchCreate {
    function create(string calldata name, string calldata symbol, string calldata description, string calldata image, uint256 minOut)
        external payable returns (address);
}

/// Launches a set of themed tokens on the CavFi Launchpad from the deployer wallet, each with a small first buy.
/// The site labels every token from this wallet "CavFi team", so nobody mistakes them for organic launches.
/// Logos are served by the site from /tokens/*.svg (upload the publish folder first).
contract SeedLaunches is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        ILaunchCreate launch = ILaunchCreate(AddrBook.get(AddrBook.read(), "launch"));
        string memory img = "https://cavfi.com/tokens/";

        string[6] memory names = ["Pumpkin Pup", "Zoomies", "Kibble", "Moon Bone", "Ghost Pup", "Treat Jar"];
        string[6] memory syms = ["PUMPKIN", "ZOOMIES", "KIBBLE", "MBONE", "BOO", "TREAT"];
        string[6] memory files = ["pumpkin.svg", "zoomies.svg", "kibble.svg", "moonbone.svg", "boo.svg", "treat.svg"];
        string[6] memory descs = [
            "Spooktober spaniel. Carved, crowned and a little bit spooky.",
            "That 3 a.m. burst of energy every dog knows. The fastest token on the curve.",
            "The original dog money. Crunchy, reliable, always in the bowl.",
            "One small bone for a dog, one giant leap for DOGE.",
            "Floats through walls, haunts the charts. Boo!",
            "Good dogs get treats. A token for every good holder."
        ];
        uint256[6] memory firstBuy = [uint256(2.5 ether), 1.5 ether, 1 ether, 2 ether, 0.8 ether, 0.5 ether];

        vm.startBroadcast(pk);
        for (uint256 i; i < 6; i++) {
            address t = launch.create{value: firstBuy[i]}(names[i], syms[i], descs[i], string.concat(img, files[i]), 0);
            console2.log(syms[i], t);
        }
        vm.stopBroadcast();
    }
}
