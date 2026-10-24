// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @title CavFi GM / GN
/// @notice Say gm and gn on-chain once per day (UTC). Saying gm on consecutive days builds a streak;
///         a 7-day gm streak mints the soulbound "Early Pup" badge automatically.
contract KingGM is ERC1155 {
    uint256 public constant EARLY_PUP = 1;
    uint256 public constant BADGE_STREAK = 7;
    string public constant name = "CavFi Early Pup";
    string public constant symbol = "PUP";

    struct Stats {
        uint32 lastGmDay; // day number (block.timestamp / 1 days) of the last gm, 0 = never
        uint32 lastGnDay;
        uint32 streak; // consecutive gm days ending at lastGmDay
        uint32 best;
        uint32 gms;
        uint32 gns;
    }

    mapping(address => Stats) public stats;
    uint256 public totalGm;
    uint256 public totalGn;

    event GM(address indexed who, uint256 indexed day, uint256 streak);
    event GN(address indexed who, uint256 indexed day);
    event EarlyPup(address indexed who);

    error AlreadyToday();

    constructor() ERC1155("") {}

    function today() public view returns (uint32) {
        return uint32(block.timestamp / 1 days);
    }

    function gm() external {
        Stats storage s = stats[msg.sender];
        uint32 d = today();
        if (s.lastGmDay == d) revert AlreadyToday();
        s.streak = (s.lastGmDay != 0 && s.lastGmDay + 1 == d) ? s.streak + 1 : 1;
        if (s.streak > s.best) s.best = s.streak;
        s.lastGmDay = d;
        s.gms++;
        totalGm++;
        emit GM(msg.sender, d, s.streak);
        if (s.streak >= BADGE_STREAK && balanceOf(msg.sender, EARLY_PUP) == 0) {
            _mint(msg.sender, EARLY_PUP, 1, "");
            emit EarlyPup(msg.sender);
        }
    }

    function gn() external {
        Stats storage s = stats[msg.sender];
        uint32 d = today();
        if (s.lastGnDay == d) revert AlreadyToday();
        s.lastGnDay = d;
        s.gns++;
        totalGn++;
        emit GN(msg.sender, d);
    }

    /// @notice Current streak as of today: it is broken if the last gm was before yesterday.
    function streakOf(address who) external view returns (uint256) {
        Stats memory s = stats[who];
        if (s.lastGmDay == 0 || s.lastGmDay + 1 < today()) return 0;
        return s.streak;
    }

    /// @notice Everything the site needs in one call.
    function info(address who)
        external
        view
        returns (bool gmToday, bool gnToday, uint256 streak, uint256 best, uint256 gms, uint256 gns, bool pup, uint256 nextDayAt)
    {
        Stats memory s = stats[who];
        uint32 d = today();
        gmToday = s.lastGmDay == d;
        gnToday = s.lastGnDay == d;
        streak = (s.lastGmDay == 0 || s.lastGmDay + 1 < d) ? 0 : s.streak;
        best = s.best;
        gms = s.gms;
        gns = s.gns;
        pup = balanceOf(who, EARLY_PUP) != 0;
        nextDayAt = (uint256(d) + 1) * 1 days;
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        require(from == address(0), "GM: soulbound");
        super._update(from, to, ids, values);
    }

    function setApprovalForAll(address, bool) public pure override {
        revert("GM: soulbound");
    }

    function uri(uint256) public pure override returns (string memory) {
        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 80"><circle cx="32" cy="32" r="30" fill="#E08A1E"/>',
            '<circle cx="32" cy="32" r="25" fill="none" stroke="#FFF8EE" stroke-opacity=".5" stroke-width="1.5"/>',
            '<path d="M18 40h28M22 40a10 10 0 0 1 20 0M32 22v4M21 27l3 3M43 27l-3 3" fill="none" stroke="#FFF8EE" stroke-width="3" stroke-linecap="round"/>',
            '<path d="M24 10l2.5-6 3.5 4 2-5 2 5 3.5-4 2.5 6z" fill="#E7B73C"/>',
            '<text x="32" y="74" text-anchor="middle" font-family="Georgia,serif" font-size="7.5" fill="#1B1A2E">Early Pup</text></svg>'
        );
        string memory json = string.concat(
            '{"name":"CavFi \\u00b7 Early Pup","description":"Said gm on CavFi 7 days in a row. Soulbound.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)), '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
