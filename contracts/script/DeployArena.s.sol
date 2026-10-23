// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingArena} from "../src/KingArena.sol";

/// Deploys KingArena (hourly prediction game) and adds "arena" to addresses.json.
/// This script never reads a private key. Sign with forge's own wallet options, e.g.
///   forge script script/DeployArena.s.sol --rpc-url dogeos --broadcast --account <keystore>
///   (or --ledger, --trezor, --interactives 1)
/// Env (all optional):
///   ARENA_FEE_TO    receives the round fee (default: you)
///   ARENA_TOKENS    comma-separated eligible tokens (2..8), each with a CavFi pair against WDOGE
///   ARENA_TIP_FUND  KingS in wei to put into the settle-tip reserve now (you must hold it)
contract DeployArena is Script {
    address private constant FOUNDRY_DEFAULT_SENDER = address(uint160(uint256(keccak256("foundry default caller"))));

    function run() external {
        string memory json = AddrBook.read();
        address kings = AddrBook.get(json, "kings");
        address wdoge = AddrBook.get(json, "wdoge");
        address factory = AddrBook.get(json, "factory");
        address[] memory tokens = vm.envOr("ARENA_TOKENS", ",", new address[](0));
        uint256 tipFund = vm.envOr("ARENA_TIP_FUND", uint256(0));

        vm.startBroadcast();
        (, address me,) = vm.readCallers();
        require(me != FOUNDRY_DEFAULT_SENDER, "DeployArena: sign with --account, --ledger or --interactives");
        address feeTo = vm.envOr("ARENA_FEE_TO", me);
        KingArena a = new KingArena(me, kings, wdoge, factory, feeTo);
        if (tokens.length > 0) a.setTokens(tokens);
        if (tipFund > 0) {
            IERC20(kings).approve(address(a), tipFund);
            a.fundTips(tipFund);
        }
        vm.stopBroadcast();

        console2.log("Arena       ", address(a));
        console2.log("Owner       ", me);
        console2.log("Fee to      ", feeTo);
        console2.log("Tokens set  ", tokens.length);
        console2.log("Tip reserve ", tipFund);
        AddrBook.write1(json, "arena", address(a));
        console2.log("Updated ../site/addresses.json");
    }
}
