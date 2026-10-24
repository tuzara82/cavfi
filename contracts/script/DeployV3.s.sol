// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingDCA} from "../src/KingDCA.sol";
import {KingQuests} from "../src/KingQuests.sol";
import {KingRaffle} from "../src/KingRaffle.sol";

/// Deploys auto-buy (DCA), daily quests and the Royal Raffle, lets the CavFi bot ("bot" in
/// addresses.json) run DCA parts, record quests and give raffle tickets, puts RAFFLE_FUND KingS
/// into the first raffle pot, and adds "dca", "quests" and "raffle" to addresses.json.
/// Env (optional): RAFFLE_FUND in wei of KingS (default 500,000 KingS; you must hold them)
contract DeployV3 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        string memory json = AddrBook.read();
        address router = AddrBook.get(json, "router");
        address wdoge = AddrBook.get(json, "wdoge");
        address kings = AddrBook.get(json, "kings");
        address bot = AddrBook.getOr(json, "bot", vm.envOr("BOT_ADDRESS", me));
        uint256 fund = vm.envOr("RAFFLE_FUND", uint256(500_000 ether));

        vm.startBroadcast(pk);
        KingDCA dca = new KingDCA(me, router, wdoge);
        dca.setKeeper(bot, true);
        KingQuests q = new KingQuests(me);
        q.setAttester(bot, true);
        KingRaffle r = new KingRaffle(me, IERC20(kings));
        r.setAttester(bot, true);
        if (fund > 0) {
            IERC20(kings).approve(address(r), fund);
            r.fund(fund);
        }
        vm.stopBroadcast();

        console2.log("DCA         ", address(dca));
        console2.log("Quests      ", address(q));
        console2.log("Raffle      ", address(r));
        console2.log("Bot allowed ", bot);
        console2.log("Raffle pot  ", fund / 1 ether, "KingS");
        string[] memory k = new string[](3);
        address[] memory v = new address[](3);
        (k[0], v[0]) = ("dca", address(dca));
        (k[1], v[1]) = ("quests", address(q));
        (k[2], v[2]) = ("raffle", address(r));
        AddrBook.write(json, k, v);
        console2.log("Updated ../site/addresses.json");
    }
}
