// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingEventBadges} from "../src/KingEventBadges.sol";

/// Deploys CavFi event badges (soulbound) with the first one, "Spooktober 2026" (id 1), awarded by the bot to
/// wallets that finish all 3 daily quests on Halloween (31 Oct 2026, UTC). Adds "events" to addresses.json.
contract DeployV9 is Script {
    string constant SVG = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="12" fill="#2A1640"/><circle cx="50" cy="12" r="6" fill="#F7E7A6"/><circle cx="52.5" cy="10.5" r="5" fill="#2A1640"/><g transform="translate(5 9) scale(.84)"><path d="M17 21 C7 23 5 36 7 45 C8.5 52 15 56 20 51 C22.5 48.5 22.5 44 22 40 L22 25 Z" fill="#B0501F"/> <path d="M47 21 C57 23 59 36 57 45 C55.5 52 49 56 44 51 C41.5 48.5 41.5 44 42 40 L42 25 Z" fill="#B0501F"/> <path d="M9.5 41 q2 4 1 8 M13 43 q1.5 4 .5 8 M54.5 41 q-2 4 -1 8 M51 43 q-1.5 4 -.5 8" stroke="#FFF8EE" stroke-opacity=".35" stroke-width="1" fill="none" stroke-linecap="round"/> <path d="M19 26 C19 17.5 45 17.5 45 26 L45.5 37 C45.5 47 39.5 53 32 53 C24.5 53 18.5 47 18.5 37 Z" fill="#B0501F"/> <path d="M29.6 18.5 C30.6 17.6 33.4 17.6 34.4 18.5 L35.4 31 C39.5 33.5 41.3 39.5 39.6 44.5 C38 49.5 26 49.5 24.4 44.5 C22.7 39.5 24.5 33.5 28.6 31 Z" fill="#FFF8EE"/> <circle cx="25.6" cy="31.5" r="3" fill="#1B1A2E"/><circle cx="38.4" cy="31.5" r="3" fill="#1B1A2E"/> <circle cx="26.6" cy="30.4" r=".95" fill="#fff"/><circle cx="39.4" cy="30.4" r=".95" fill="#fff"/> <ellipse cx="32" cy="39.6" rx="3.3" ry="2.4" fill="#1B1A2E"/> <path d="M32 42 v2.6 M28.6 45.6 q3.4 2.4 6.8 0" stroke="#1B1A2E" stroke-width="1.3" fill="none" stroke-linecap="round"/></g><path d="M17 21 L40 20 L30 2 Z" fill="#1B1A2E" stroke="#F28C28" stroke-width=".8"/><path d="M12 21.5 Q28 17 46 21.5 Q28 24.5 12 21.5 Z" fill="#1B1A2E" stroke="#F28C28" stroke-width=".8"/><rect x="20" y="17.5" width="17" height="2.4" rx=".6" fill="#F28C28"/><ellipse cx="51" cy="51" rx="8" ry="6.5" fill="#F28C28"/><path d="M47 51 q4 -6 8 0 M51 44.5 v-3" stroke="#B4532A" stroke-width="1" fill="none"/><path d="M48 50 l1.5 -1.5 l1.5 1.5 z M52 50 l1.5 -1.5 l1.5 1.5 z M48.5 53.5 q2.5 2 5 0" fill="#2A1640" stroke="#2A1640" stroke-width=".6"/><text x="32" y="61" text-anchor="middle" font-family="Georgia,serif" font-size="5" fill="#F7E7A6">Spooktober 2026</text></svg>';

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        string memory json = AddrBook.read();
        address bot = AddrBook.getOr(json, "bot", vm.envOr("BOT_ADDRESS", me));
        vm.startBroadcast(pk);
        KingEventBadges e = new KingEventBadges(me, bot);
        e.addBadge(1, "Spooktober 2026", "Finished all 3 CavFi daily quests on Halloween, 31 October 2026 (UTC).", SVG);
        vm.stopBroadcast();
        console2.log("Event badges", address(e));
        console2.log("Minter (bot) ", bot);
        AddrBook.write1(json, "events", address(e));
        console2.log("Updated ../site/addresses.json");
    }
}
