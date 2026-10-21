// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {KingLaunch} from "../src/KingLaunch.sol";
import {KingPair} from "../src/KingPair.sol";

interface IFactoryView {
    function getPair(address, address) external view returns (address);
}

/// Deploys the CavFi launchpad (KingLaunch) and adds "launch" to ../site/addresses.json.
///
/// Env (optional):
///   LAUNCH_TARGET      DOGE a token must raise to graduate, whole DOGE (default 20)
///   LAUNCH_CREATE_FEE  DOGE charged to launch a token, in milli-DOGE (default 0)
///   FEE_TO             receives the 1% curve fee (default: you)
contract DeployLaunch is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        uint256 target = vm.envOr("LAUNCH_TARGET", uint256(20)) * 1 ether;
        uint256 createFee = vm.envOr("LAUNCH_CREATE_FEE", uint256(0)) * 1e15;
        address feeTo = vm.envOr("FEE_TO", me);

        string memory json = AddrBook.read();
        address factory = AddrBook.get(json, "factory");
        address wdoge = AddrBook.get(json, "wdoge");
        address kings = AddrBook.get(json, "kings");

        // Can we predict CavFi pool addresses? Check the formula against the live KingS/WDOGE pool.
        bytes32 hash = keccak256(type(KingPair).creationCode);
        address live = IFactoryView(factory).getPair(kings, wdoge);
        (address t0, address t1) = kings < wdoge ? (kings, wdoge) : (wdoge, kings);
        address guess = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", factory, keccak256(abi.encodePacked(t0, t1)), hash)))));
        if (live == address(0) || guess != live) {
            console2.log("Pool address formula did not match; pools will be created at launch time instead.");
            hash = bytes32(0);
        }

        vm.startBroadcast(pk);
        KingLaunch lp = new KingLaunch(factory, wdoge, hash, me, feeTo, target, createFee);
        vm.stopBroadcast();

        console2.log("Launchpad   ", address(lp));
        console2.log("Graduates at", target / 1e15, "milli-DOGE");
        console2.log("Create fee  ", createFee / 1e15, "milli-DOGE");
        console2.log("Fee to      ", feeTo);
        console2.log("Predict pool", hash != bytes32(0));
        AddrBook.write1(json, "launch", address(lp));
        console2.log("Updated ../site/addresses.json");
    }
}
