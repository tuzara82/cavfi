// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title KingS — the KingSwap token
/// @notice Fixed supply, minted once to the deployer. No owner, no mint function, no taxes.
contract KingS is ERC20, ERC20Burnable {
    constructor(address to, uint256 supply) ERC20("KingSwap Token", "KingS") {
        _mint(to, supply);
    }
}
