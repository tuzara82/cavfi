// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingCavaliers} from "../src/KingCavaliers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Deploys the CavFi Cavaliers NFT collection and adds "nft" to addresses.json.
/// Env (all optional):
///   NFT_SUPPLY        max supply                         (default 2000)
///   NFT_PRICE         mint price in wei of DOGE          (default 1 DOGE)
///   NFT_REWARD        KingS (in whole tokens) to fund staking rewards with, from your wallet (default 0)
///   NFT_REWARD_DAYS   how many days that reward lasts    (default 30)
contract DeployCavaliers is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        string memory json = AddrBook.read();
        address kings = AddrBook.get(json, "kings");
        uint256 supply = vm.envOr("NFT_SUPPLY", uint256(2000));
        uint256 price = vm.envOr("NFT_PRICE", uint256(1 ether));
        uint256 reward = vm.envOr("NFT_REWARD", uint256(0)) * 1e18;
        uint256 days_ = vm.envOr("NFT_REWARD_DAYS", uint256(30));

        vm.startBroadcast(pk);
        KingCavaliers c = new KingCavaliers(me, IERC20(kings), supply, price);
        if (reward > 0) {
            IERC20(kings).approve(address(c), reward);
            c.notifyReward(reward, days_ * 1 days);
        }
        vm.stopBroadcast();
        console2.log("Cavaliers   ", address(c));
        console2.log("Max supply  ", supply);
        console2.log("Price (wei) ", price);
        console2.log("KingS reward", reward / 1e18);
        AddrBook.write1(json, "nft", address(c));
        console2.log("Updated ../site/addresses.json");
    }
}
