// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// Rewrites ../site/addresses.json keeping every existing entry and setting/overriding the given ones.
library AddrBook {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    string internal constant PATH = "../site/addresses.json";

    function read() internal view returns (string memory) {
        return vm.readFile(PATH);
    }

    function has(string memory json, string memory key) internal view returns (bool) {
        return vm.keyExistsJson(json, string.concat(".", key));
    }

    function get(string memory json, string memory key) internal pure returns (address) {
        return vm.parseJsonAddress(json, string.concat(".", key));
    }

    function getOr(string memory json, string memory key, address fallback_) internal view returns (address) {
        return has(json, key) ? get(json, key) : fallback_;
    }

    function write(string memory json, string[] memory keys, address[] memory vals) internal {
        string memory o = "addrbook";
        string memory out = vm.serializeUint(o, "chainId", block.chainid);
        string[] memory existing = vm.parseJsonKeys(json, "$");
        for (uint256 i; i < existing.length; i++) {
            string memory k = existing[i];
            if (keccak256(bytes(k)) == keccak256("chainId")) continue;
            bool overridden;
            for (uint256 j; j < keys.length; j++) if (keccak256(bytes(keys[j])) == keccak256(bytes(k))) overridden = true;
            if (!overridden) out = vm.serializeAddress(o, k, get(json, k));
        }
        for (uint256 j; j < keys.length; j++) out = vm.serializeAddress(o, keys[j], vals[j]);
        vm.writeJson(out, PATH);
    }

    function write1(string memory json, string memory key, address val) internal {
        string[] memory k = new string[](1);
        address[] memory v = new address[](1);
        k[0] = key;
        v[0] = val;
        write(json, k, v);
    }
}
