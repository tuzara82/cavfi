// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingPredict3, IRedStoneFeed} from "../src/KingPredict3.sol";
import {KingGuess3, IRedStoneFeedG} from "../src/KingGuess3.sol";

interface IPredictPrev { function count() external view returns (uint256); }
interface IGuessPrev {
    function prize() external view returns (uint256);
    function owner() external view returns (address);
    function withdraw(uint256 amount, address to) external;
}

/// Predict v3 and Guess v3: daily/weekly markets and the daily game are decided by RedStone's DOGE/USD push feed
/// on DogeOS (no API key needed); hourly "up or down" markets keep RedStone's signed data for the exact second.
/// - v3 market ids continue after the last v2 market (stop the bot before running this).
/// - The v2 contracts stay as "predictV2" / "guessV2" so their markets can finish or refund and people can claim.
/// - Guess v3 gets GUESS_FUND KingS (default 300,000) from the deployer; Guess v2 keeps 2 days of prizes and
///   returns the rest of its fund to the deployer (MOVE_V2_FUND=0 to skip).
/// REDSTONE_FEED: the DOGE/USD push feed (default: RedStone's DOGE feed on DogeOS Chikyu testnet).
contract DeployV8 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        string memory json = AddrBook.read();
        address kings = AddrBook.get(json, "kings");
        address bot = AddrBook.getOr(json, "bot", vm.envOr("BOT_ADDRESS", me));
        address p2 = AddrBook.getOr(json, "predictV2", AddrBook.get(json, "predict"));
        address g2 = AddrBook.getOr(json, "guessV2", AddrBook.get(json, "guess"));
        address feed = vm.envOr("REDSTONE_FEED", address(0x434F8D17c0301cfEa143dba912972E24B827C968));
        uint256 prize = vm.envOr("GUESS_PRIZE", uint256(10_000 ether));
        uint256 fund = vm.envOr("GUESS_FUND", uint256(300_000 ether));
        bool moveV2 = vm.envOr("MOVE_V2_FUND", uint256(1)) == 1;
        uint256 firstId = IPredictPrev(p2).count();

        vm.startBroadcast(pk);
        KingPredict3 p = new KingPredict3(me, IERC20(kings), bot, firstId, IRedStoneFeed(feed));
        KingGuess3 g = new KingGuess3(me, IERC20(kings), prize, IRedStoneFeedG(feed));
        if (fund > 0) IERC20(kings).transfer(address(g), fund);
        uint256 back;
        if (moveV2 && IGuessPrev(g2).owner() == me) {
            uint256 bal = IERC20(kings).balanceOf(g2);
            uint256 keep = 2 * IGuessPrev(g2).prize();
            if (bal > keep) { back = bal - keep; IGuessPrev(g2).withdraw(back, me); }
        }
        vm.stopBroadcast();

        console2.log("Predict v3  ", address(p));
        console2.log("  first id  ", firstId);
        console2.log("Guess v3    ", address(g));
        console2.log("  fund      ", fund / 1 ether, "KingS");
        console2.log("Guess v2 fund returned", back / 1 ether, "KingS");
        console2.log("RedStone feed", feed);

        string[] memory k = new string[](4);
        address[] memory v = new address[](4);
        k[0] = "predict"; v[0] = address(p);
        k[1] = "guess"; v[1] = address(g);
        k[2] = "predictV2"; v[2] = p2;
        k[3] = "guessV2"; v[3] = g2;
        AddrBook.write(json, k, v);
        console2.log("Updated ../site/addresses.json");
    }
}
