// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingGuess} from "../src/KingGuess.sol";

/// Deploys "Guess the DOGE price" (the CavFi bot as price oracle), funds its prize pool from the deployer
/// and adds "guess" to addresses.json.
/// GUESS_PRIZE: KingS per day (default 10,000). GUESS_FUND: KingS sent to the prize pool (default 300,000 = 30 days).
contract DeployV5 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        string memory json = AddrBook.read();
        address kings = AddrBook.get(json, "kings");
        address bot = AddrBook.getOr(json, "bot", vm.envOr("BOT_ADDRESS", me));
        uint256 prize = vm.envOr("GUESS_PRIZE", uint256(10_000 ether));
        uint256 fund = vm.envOr("GUESS_FUND", uint256(300_000 ether));

        vm.startBroadcast(pk);
        KingGuess g = new KingGuess(me, IERC20(kings), bot, prize);
        if (fund > 0) IERC20(kings).transfer(address(g), fund);
        vm.stopBroadcast();

        console2.log("Guess       ", address(g));
        console2.log("Oracle (bot)", bot);
        console2.log("Prize a day ", prize / 1 ether, "KingS");
        console2.log("Prize fund  ", fund / 1 ether, "KingS");
        AddrBook.write1(json, "guess", address(g));
        console2.log("Updated ../site/addresses.json");
    }
}
