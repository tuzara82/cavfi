// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Test stablecoin for the DogeOS testnet (TESTNET ONLY, no value)
/// @notice 6 decimals like real USDT/USDC. Anyone can claim 1,000 per hour from faucet().
contract TestStable is ERC20 {
    uint8 private immutable _dec;
    uint256 public constant FAUCET_AMOUNT = 1_000 * 1e6;
    uint256 public constant FAUCET_COOLDOWN = 1 hours;
    mapping(address => uint256) public lastClaim;

    constructor(string memory name_, string memory symbol_, address to, uint256 initialSupply)
        ERC20(name_, symbol_)
    {
        _dec = 6;
        _mint(to, initialSupply);
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function nextClaimAt(address who) external view returns (uint256) {
        uint256 l = lastClaim[who];
        return l == 0 ? 0 : l + FAUCET_COOLDOWN;
    }

    function faucet() external {
        uint256 l = lastClaim[msg.sender];
        require(l == 0 || block.timestamp >= l + FAUCET_COOLDOWN, "TestStable: wait 1 hour between claims");
        lastClaim[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
    }
}
