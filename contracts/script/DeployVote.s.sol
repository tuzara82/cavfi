// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KingVote, IVoteFarm} from "../src/KingVote.sol";

interface IOwnedFarm { function owner() external view returns (address); function transferOwnership(address) external; }

/// Deploys KingVote, hands it the KingFarm, and adds "vote" to ../site/addresses.json.
/// From then on KingS holders decide the farm weights; you can still add pools and fund
/// rewards through KingVote, and `releaseFarm` gives the farm back to you.
/// Env (optional): VOTE_BASE  weight every pool keeps (default 10; votes share 1000)
contract DeployVote is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        uint256 base = vm.envOr("VOTE_BASE", uint256(10));
        string memory json = AddrBook.read();
        address farm = AddrBook.get(json, "farm");
        address kings = AddrBook.get(json, "kings");
        require(IOwnedFarm(farm).owner() == me, "You are not the farm owner");
        vm.startBroadcast(pk);
        KingVote kv = new KingVote(IERC20(kings), IVoteFarm(farm), me, base);
        IOwnedFarm(farm).transferOwnership(address(kv));
        vm.stopBroadcast();
        console2.log("KingVote    ", address(kv));
        console2.log("Farm owner  ", IOwnedFarm(farm).owner());
        AddrBook.write1(json, "vote", address(kv));
        console2.log("Updated ../site/addresses.json");
    }
}
