// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingPredict2} from "../src/KingPredict2.sol";
import {KingGuess2} from "../src/KingGuess2.sol";

interface IPredictV1 { function count() external view returns (uint256); }
interface IGuessV1 {
    function prize() external view returns (uint256);
    function owner() external view returns (address);
    function withdraw(uint256 amount, address to) external;
}

/// Predict v2 and Guess v2: markets and the daily game are decided by RedStone's signed DOGE/USD price.
/// - Predict v2 market ids continue after the last v1 market (stop the bot before running this).
/// - The v1 contracts stay as "predictV1" / "guessV1" so open v1 markets can finish and people can claim.
/// - Guess v2 gets GUESS_FUND KingS (default 300,000) from the deployer. Guess v1 keeps 2 days of prizes
///   for the days still to settle; the rest of its fund goes back to the deployer (MOVE_V1_FUND=0 to skip).
contract DeployV6 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        string memory json = AddrBook.read();
        address kings = AddrBook.get(json, "kings");
        address bot = AddrBook.getOr(json, "bot", vm.envOr("BOT_ADDRESS", me));
        address p1 = AddrBook.getOr(json, "predictV1", AddrBook.get(json, "predict"));
        address g1 = AddrBook.getOr(json, "guessV1", AddrBook.get(json, "guess"));
        uint256 prize = vm.envOr("GUESS_PRIZE", uint256(10_000 ether));
        uint256 fund = vm.envOr("GUESS_FUND", uint256(300_000 ether));
        bool moveV1 = vm.envOr("MOVE_V1_FUND", uint256(1)) == 1;
        uint256 firstId = IPredictV1(p1).count();

        vm.startBroadcast(pk);
        KingPredict2 p = new KingPredict2(me, IERC20(kings), bot, firstId);
        KingGuess2 g = new KingGuess2(me, IERC20(kings), prize);
        if (fund > 0) IERC20(kings).transfer(address(g), fund);
        uint256 back;
        if (moveV1 && IGuessV1(g1).owner() == me) {
            uint256 bal = IERC20(kings).balanceOf(g1);
            uint256 keep = 2 * IGuessV1(g1).prize();
            if (bal > keep) { back = bal - keep; IGuessV1(g1).withdraw(back, me); }
        }
        vm.stopBroadcast();

        console2.log("Predict v2  ", address(p));
        console2.log("  first id  ", firstId);
        console2.log("Guess v2    ", address(g));
        console2.log("  prize/day ", prize / 1 ether, "KingS");
        console2.log("  fund      ", fund / 1 ether, "KingS");
        console2.log("Guess v1 fund returned", back / 1 ether, "KingS");
        console2.log("Market creator (bot)", bot);

        string[] memory k = new string[](4);
        address[] memory v = new address[](4);
        k[0] = "predict"; v[0] = address(p);
        k[1] = "guess"; v[1] = address(g);
        k[2] = "predictV1"; v[2] = p1;
        k[3] = "guessV1"; v[3] = g1;
        AddrBook.write(json, k, v);
        console2.log("Updated ../site/addresses.json");
    }
}
