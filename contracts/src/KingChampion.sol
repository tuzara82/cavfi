// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

interface IKingArenaView {
    struct Round {
        uint64 start;
        uint64 end;
        uint16 feeBps;
        uint8 winnerMask;
        bool settled;
        uint256 staked;
        uint256 rollover;
        uint256 winnerStake;
        uint256 payout;
    }

    function getRound(uint256 id) external view returns (Round memory);
    function myStakes(uint256 id, address user) external view returns (uint256[] memory);
}

/// @title CavFi Arena Champion badge
/// @notice A soulbound badge for anyone who backed a winning token in a settled CavFi Arena round.
///         Anyone can claim it for themselves: the contract checks the win directly in KingArena,
///         so no bot or owner is involved and nobody can hand it out.
contract KingChampion is ERC1155 {
    uint256 public constant CHAMPION = 1;
    string public constant name = "CavFi Arena Champion";
    string public constant symbol = "CHAMP";

    IKingArenaView public immutable arena;
    /// the round a wallet proved its win with
    mapping(address => uint256) public wonRound;

    event Champion(address indexed who, uint256 indexed roundId);

    constructor(address arena_) ERC1155("") {
        require(arena_ != address(0), "Champion: zero arena");
        arena = IKingArenaView(arena_);
    }

    /// @notice True if `who` had a stake on a winning token of round `roundId` (settled, not rolled over).
    function wonIn(uint256 roundId, address who) public view returns (bool) {
        IKingArenaView.Round memory r = arena.getRound(roundId);
        if (!r.settled || r.winnerStake == 0) return false;
        uint256[] memory stakes = arena.myStakes(roundId, who);
        for (uint256 i; i < stakes.length; i++) {
            if (stakes[i] != 0 && (uint256(r.winnerMask) >> i) & 1 == 1) return true;
        }
        return false;
    }

    function claim(uint256 roundId) external {
        require(balanceOf(msg.sender, CHAMPION) == 0, "Champion: already yours");
        require(wonIn(roundId, msg.sender), "Champion: no win in that round");
        wonRound[msg.sender] = roundId;
        _mint(msg.sender, CHAMPION, 1, "");
        emit Champion(msg.sender, roundId);
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        require(from == address(0), "Champion: soulbound");
        super._update(from, to, ids, values);
    }

    function setApprovalForAll(address, bool) public pure override {
        revert("Champion: soulbound");
    }

    function uri(uint256) public pure override returns (string memory) {
        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 80"><circle cx="32" cy="32" r="30" fill="#9C2F55"/>',
            '<circle cx="32" cy="32" r="25" fill="none" stroke="#FFF8EE" stroke-opacity=".5" stroke-width="1.5"/>',
            '<path d="M23 20h18v6a9 9 0 0 1-18 0zM23 22h-4a5 5 0 0 0 5 6M41 22h4a5 5 0 0 1-5 6M32 35v6M26 45h12" fill="none" stroke="#FFF8EE" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>',
            '<path d="M24 10l2.5-6 3.5 4 2-5 2 5 3.5-4 2.5 6z" fill="#E7B73C"/>',
            '<text x="32" y="74" text-anchor="middle" font-family="Georgia,serif" font-size="7" fill="#1B1A2E">Arena Champion</text></svg>'
        );
        string memory json = string.concat(
            '{"name":"CavFi \\u00b7 Arena Champion","description":"Backed the winning token in a CavFi Arena round. Soulbound.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
