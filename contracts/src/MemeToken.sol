// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title CavFi launchpad meme token
/// @notice Fixed supply of 1,000,000,000 tokens, all minted to the launchpad. While the token is
///         still on its bonding curve nobody can send it to its future CavFi pool, so nobody can
///         seed that pool at a fake price before the launchpad adds the real liquidity.
contract MemeToken is ERC20 {
    address public immutable launchpad;
    address public pair;
    bool public graduated;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        launchpad = msg.sender;
        _mint(msg.sender, 1_000_000_000 ether);
    }

    /// @notice Set once by the launchpad, right after deployment and before any token leaves it.
    function setPair(address pair_) external {
        require(msg.sender == launchpad && pair == address(0) && pair_ != address(0), "MemeToken: FORBIDDEN");
        pair = pair_;
    }

    function markGraduated() external {
        require(msg.sender == launchpad, "MemeToken: FORBIDDEN");
        graduated = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!graduated && to == pair && from != launchpad) revert("MemeToken: pool opens after graduation");
        super._update(from, to, value);
    }
}
