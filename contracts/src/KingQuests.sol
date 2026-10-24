// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @title CavFi daily quests
/// @notice Every UTC day has 3 quests (the site shows them; the list is derived from the day number).
///         After a day ends, the CavFi bot checks each wallet's transactions of that day and records how
///         many of the 3 it completed. Completing all 3 on consecutive days builds a streak; a 7-day
///         streak mints the soulbound "Questmaster" badge automatically.
/// @dev The bot is the attester: it can only record a finished day (before today), at most 30 days
///      back, and each wallet/day once. It cannot take anything from anyone.
contract KingQuests is ERC1155, Ownable {
    uint256 public constant QUESTMASTER = 1;
    uint256 public constant BADGE_STREAK = 7;
    uint8 public constant PER_DAY = 3;
    string public constant name = "CavFi Questmaster";
    string public constant symbol = "QUEST";

    struct Stats {
        uint32 lastFullDay; // last day with all 3 quests done
        uint32 streak;      // consecutive full days ending at lastFullDay
        uint32 best;
        uint32 fullDays;
        uint32 quests;      // quests completed in total
    }

    mapping(address => bool) public attester;
    mapping(address => Stats) public stats;
    mapping(address => mapping(uint32 => uint8)) public doneOf; // wallet => day => quests done (0..3)

    event QuestDay(address indexed who, uint32 indexed day, uint8 done, uint32 streak);
    event Questmaster(address indexed who);
    event AttesterSet(address indexed who, bool allowed);

    constructor(address owner_) ERC1155("") Ownable(owner_) {}

    function setAttester(address a, bool allowed) external onlyOwner {
        attester[a] = allowed;
        emit AttesterSet(a, allowed);
    }

    function today() public view returns (uint32) {
        return uint32(block.timestamp / 1 days);
    }

    /// @notice Record a finished day. `done[i]` = quests (1..3) that `users[i]` completed on `day`.
    ///         Days must be recorded in order per wallet for the streak to count them.
    function record(uint32 day, address[] calldata users, uint8[] calldata done) external {
        require(attester[msg.sender], "Quests: not attester");
        require(users.length == done.length, "Quests: length");
        uint32 t = today();
        require(day < t && day + 30 >= t, "Quests: day");
        for (uint256 i; i < users.length; i++) {
            address u = users[i];
            uint8 d = done[i];
            if (d == 0 || d > PER_DAY || doneOf[u][day] != 0) continue;
            doneOf[u][day] = d;
            Stats storage s = stats[u];
            s.quests += d;
            if (d == PER_DAY && day > s.lastFullDay) {
                s.streak = (s.lastFullDay != 0 && s.lastFullDay + 1 == day) ? s.streak + 1 : 1;
                s.lastFullDay = day;
                s.fullDays += 1;
                if (s.streak > s.best) s.best = s.streak;
                if (s.streak >= BADGE_STREAK && balanceOf(u, QUESTMASTER) == 0) {
                    _mint(u, QUESTMASTER, 1, "");
                    emit Questmaster(u);
                }
            }
            emit QuestDay(u, day, d, s.streak);
        }
    }

    /// @notice Streak as of today: still alive if the last full day was yesterday or today.
    function info(address who) external view returns (uint256 streak, uint256 best, uint256 fullDays, uint256 quests, bool badge, uint8 yesterday) {
        Stats memory s = stats[who];
        uint32 t = today();
        streak = (s.lastFullDay != 0 && s.lastFullDay + 2 >= t) ? s.streak : 0;
        best = s.best;
        fullDays = s.fullDays;
        quests = s.quests;
        badge = balanceOf(who, QUESTMASTER) != 0;
        yesterday = t > 0 ? doneOf[who][t - 1] : 0;
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        require(from == address(0), "Quests: soulbound");
        super._update(from, to, ids, values);
    }

    function setApprovalForAll(address, bool) public pure override {
        revert("Quests: soulbound");
    }

    function uri(uint256) public pure override returns (string memory) {
        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 80"><circle cx="32" cy="32" r="30" fill="#1E5FA8"/>',
            '<circle cx="32" cy="32" r="25" fill="none" stroke="#FFF8EE" stroke-opacity=".5" stroke-width="1.5"/>',
            '<path d="M22 22h20v24H22z M26 29l3 3 5-6 M26 38h12" fill="none" stroke="#FFF8EE" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>',
            '<path d="M24 10l2.5-6 3.5 4 2-5 2 5 3.5-4 2.5 6z" fill="#E7B73C"/>',
            '<text x="32" y="74" text-anchor="middle" font-family="Georgia,serif" font-size="7.5" fill="#1B1A2E">Questmaster</text></svg>'
        );
        string memory json = string.concat(
            '{"name":"CavFi - Questmaster","description":"Finished all 3 CavFi daily quests 7 days in a row. Soulbound.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)), '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
