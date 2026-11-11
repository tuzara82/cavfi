// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingHunt} from "../src/KingHunt.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Opens hunt #2 on the existing KingHunt contract: "The CavFi Heist", five clues to crack the royal vault.
/// The answers are NOT in this file (the repo is public): pass them as HUNT_ANSWERS="a,b,c,d,e",
/// lowercase letters and digits only, in the order of the clues below. Only their hashes go on chain.
/// HUNT_PRIZE (KingS, default 100,000) is pulled from the deployer. HUNT_DAYS defaults to 7.
contract DeployV14 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        string memory json = AddrBook.read();
        address kings = AddrBook.get(json, "kings");
        KingHunt h = KingHunt(AddrBook.get(json, "hunt"));
        string[] memory answers = vm.envString("HUNT_ANSWERS", ",");
        uint256 prize = vm.envOr("HUNT_PRIZE", uint256(100_000 ether));
        uint256 days_ = vm.envOr("HUNT_DAYS", uint256(7));

        string[] memory clues = new string[](5);
        clues[0] = "The guard dog: a crowned spaniel watches the CavFi vault. What breed is it? One word.";
        clues[1] = "The jewel: the biggest prize on the Royal Wheel is a crown worth this many KingS. Digits only.";
        clues[2] = "The drop: in Plinko the getaway ball falls through the pegs. How many bins can it land in?";
        clues[3] = "The rival: in every Arena round each token races against one coin. Name it.";
        clues[4] = "The inside man: the CavFi bot runs the house for every game, and it registered a .cav name. Find it on the Names page. What is it, without .cav?";
        require(answers.length == clues.length, "HUNT_ANSWERS needs 5 answers");

        uint256 id = h.count();
        bytes32[] memory keys = new bytes32[](clues.length);
        for (uint256 i; i < clues.length; i++) {
            bytes memory a = bytes(answers[i]);
            require(a.length > 0, "empty answer");
            for (uint256 j; j < a.length; j++) {
                bytes1 c = a[j];
                require((c >= "a" && c <= "z") || (c >= "0" && c <= "9"), "answers: lowercase a-z and 0-9 only");
            }
            keys[i] = keccak256(abi.encodePacked(id, uint8(i), answers[i]));
        }
        vm.startBroadcast(pk);
        IERC20(kings).approve(address(h), prize);
        h.create("The CavFi Heist", uint64(block.timestamp), uint64(block.timestamp + days_ * 1 days), clues, keys, prize);
        vm.stopBroadcast();
        console2.log("Hunt contract", address(h));
        console2.log("Hunt id      ", id);
    }
}
