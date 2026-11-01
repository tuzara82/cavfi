// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingGames2} from "../src/KingGames2.sol";

interface IGamesV1 {
    function free() external view returns (uint256);
    function withdraw(uint256 amount, address payable to) external;
    function owner() external view returns (address);
}

/// Deploys CavFi Games v2 (Coin Flip, Dice, Limbo, Royal Wheel, Plinko, Higher or Lower) with the bot as the house.
/// Moves the free bankroll of Games v1 into it (what is reserved for v1's pending bets stays until they settle)
/// and adds GAMES_FUND more DOGE (default 0). addresses.json: "games" = v2, "gamesV1" = the old contract.
contract DeployV12 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        string memory json = AddrBook.read();
        address bot = AddrBook.getOr(json, "bot", vm.envOr("BOT_ADDRESS", me));
        address old = AddrBook.getOr(json, "games", address(0));
        uint256 extra = vm.envOr("GAMES_FUND", uint256(0));

        vm.startBroadcast(pk);
        KingGames2 g = new KingGames2(me, bot);
        uint256 moved;
        if (old != address(0) && IGamesV1(old).owner() == me) {
            moved = IGamesV1(old).free();
            if (moved > 0) IGamesV1(old).withdraw(moved, payable(me));
        }
        if (moved + extra > 0) {
            (bool ok,) = address(g).call{value: moved + extra}("");
            require(ok, "fund");
        }
        vm.stopBroadcast();
        console2.log("Games v2   ", address(g));
        console2.log("Games v1   ", old);
        console2.log("Bankroll   ", moved + extra);
        string[] memory keys = new string[](old != address(0) ? 2 : 1);
        address[] memory vals = new address[](keys.length);
        keys[0] = "games"; vals[0] = address(g);
        if (old != address(0)) { keys[1] = "gamesV1"; vals[1] = old; }
        AddrBook.write(json, keys, vals);
        console2.log("Updated ../site/addresses.json");
    }
}
