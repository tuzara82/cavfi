// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @title CavFi event badges: soulbound, one per event (e.g. "Spooktober 2026")
/// @notice The owner adds an event badge with its on-chain art; the CavFi bot awards it to the wallets that
///         met the event's rule (for Spooktober: all 3 daily quests done on Halloween, UTC). Badges cannot be
///         transferred. Each wallet holds each badge at most once.
contract KingEventBadges is ERC1155, Ownable {
    struct Badge {
        string name;
        string description;
        string svg;
        uint256 holders;
    }

    address public minter;
    mapping(uint256 => Badge) internal badges;
    uint256[] public ids;

    event BadgeAdded(uint256 indexed id, string name);
    event Awarded(uint256 indexed id, address indexed who);
    event MinterSet(address minter);

    constructor(address owner_, address minter_) ERC1155("") Ownable(owner_) {
        minter = minter_;
    }

    function setMinter(address m) external onlyOwner { minter = m; emit MinterSet(m); }

    function addBadge(uint256 id, string calldata name, string calldata description, string calldata svg) external onlyOwner {
        require(id > 0 && bytes(badges[id].name).length == 0, "Events: id");
        require(bytes(name).length > 0 && bytes(svg).length > 0, "Events: badge");
        badges[id] = Badge(name, description, svg, 0);
        ids.push(id);
        emit BadgeAdded(id, name);
    }

    /// @notice Already owned: skipped, not reverted.
    function award(address[] calldata to, uint256 id) external {
        require(msg.sender == minter || msg.sender == owner(), "Events: not minter");
        require(bytes(badges[id].name).length > 0, "Events: no badge");
        for (uint256 i; i < to.length; i++) {
            if (balanceOf(to[i], id) > 0) continue;
            badges[id].holders++;
            _mint(to[i], id, 1, "");
            emit Awarded(id, to[i]);
        }
    }

    function badge(uint256 id) external view returns (Badge memory) { return badges[id]; }
    function count() external view returns (uint256) { return ids.length; }

    function uri(uint256 id) public view override returns (string memory) {
        Badge storage b = badges[id];
        string memory json = string.concat('{"name":"CavFi \\u00b7 ', b.name, '","description":"', b.description,
            ' Soulbound.","image":"data:image/svg+xml;base64,', Base64.encode(bytes(b.svg)), '"}');
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    // soulbound: only minting
    function _update(address from, address to, uint256[] memory ids_, uint256[] memory values) internal override {
        require(from == address(0), "Events: soulbound");
        super._update(from, to, ids_, values);
    }

    function setApprovalForAll(address, bool) public pure override { revert("Events: soulbound"); }
}
