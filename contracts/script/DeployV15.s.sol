// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingRaid} from "../src/KingRaid.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Deploys the CavFi Raid (a co-op boss everyone fights together), makes the bot its attester and opens the first
/// raid: "The Fat Cat". RAID_HP (default 5,000), RAID_PRIZE (KingS, default 100,000, pulled from the deployer),
/// RAID_DAYS (default 7). Adds "raid" to addresses.json.
contract DeployV15 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        string memory json = AddrBook.read();
        address kings = AddrBook.get(json, "kings");
        address bot = AddrBook.getOr(json, "bot", vm.envOr("BOT_ADDRESS", me));
        uint256 hp = vm.envOr("RAID_HP", uint256(5_000));
        uint256 prize = vm.envOr("RAID_PRIZE", uint256(100_000 ether));
        uint256 days_ = vm.envOr("RAID_DAYS", uint256(7));
        vm.startBroadcast(pk);
        KingRaid r = new KingRaid(me, IERC20(kings));
        r.setAttester(bot, true);
        IERC20(kings).approve(address(r), prize);
        r.create("The Fat Cat", uint64(block.timestamp), uint64(block.timestamp + days_ * 1 days), uint128(hp), prize);
        vm.stopBroadcast();
        console2.log("Raid       ", address(r));
        console2.log("Attester   ", bot);
        console2.log("Boss HP    ", hp);
        AddrBook.write1(json, "raid", address(r));
        console2.log("Updated ../site/addresses.json");
    }
}
