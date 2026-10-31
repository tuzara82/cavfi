// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingHunt} from "../src/KingHunt.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Deploys the CavFi Royal Treasure Hunt (unless HUNT is set to an existing one) and opens a hunt.
/// The answers are NOT in this file (the repo is public): pass them as HUNT_ANSWERS="a,b,c,d,e",
/// lowercase letters and digits only, in the order of the riddles below. Only their hashes go on chain.
/// HUNT_PRIZE (KingS, default 100,000) is pulled from the deployer. HUNT_DAYS defaults to 7.
contract DeployV11 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        string memory json = AddrBook.read();
        address kings = AddrBook.get(json, "kings");
        string[] memory answers = vm.envString("HUNT_ANSWERS", ",");
        uint256 prize = vm.envOr("HUNT_PRIZE", uint256(100_000 ether));
        uint256 days_ = vm.envOr("HUNT_DAYS", uint256(7));

        string[] memory clues = new string[](5);
        clues[0] = "The first meme ever to graduate on the CavFi Launchpad. Answer with its ticker.";
        clues[1] = "Say gm seven days in a row and a soulbound pup is yours. What is that badge called?";
        clues[2] = "In Dice, roll under 3 and win. How many times your stake comes back?";
        clues[3] = "One of the CavFi team's Halloween launches floats through walls and haunts the charts. Its ticker?";
        clues[4] = "Bronze, Silver, Gold... the rarest crown a Cavalier can wear.";
        require(answers.length == clues.length, "HUNT_ANSWERS needs 5 answers");

        vm.startBroadcast(pk);
        KingHunt h = AddrBook.has(json, "hunt") && vm.envOr("NEW_HUNT_CONTRACT", false) == false
            ? KingHunt(AddrBook.get(json, "hunt"))
            : new KingHunt(me, IERC20(kings));
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
        IERC20(kings).approve(address(h), prize);
        h.create(string.concat("Royal Treasure Hunt #", vm.toString(id + 1)), uint64(block.timestamp), uint64(block.timestamp + days_ * 1 days), clues, keys, prize);
        vm.stopBroadcast();
        console2.log("Hunt contract", address(h));
        console2.log("Hunt id      ", id);
        AddrBook.write1(json, "hunt", address(h));
        console2.log("Updated ../site/addresses.json");
    }
}
