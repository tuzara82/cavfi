// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @title CavFi social: referrals, token comments and the Royal Herald badge
/// @notice * Referrals: a new user links their wallet to whoever invited them, once and for good.
///         * Comments: short public messages under any launchpad token, stored as events.
///         * Royal Herald: a soulbound badge the CavFi bot awards to people whose invites became traders.
contract KingSocial is ERC1155, Ownable {
    uint256 public constant HERALD = 1;
    uint256 public constant COMMENT_GAP = 20; // seconds between comments from one wallet
    string public constant name = "CavFi Royal Herald";
    string public constant symbol = "HERALD";

    address public minter;
    mapping(address => address) public referrerOf;
    mapping(address => uint256) public refCount;
    address[] internal referees;
    mapping(address => uint256) public lastComment;
    uint256 public commentCount;

    event Referred(address indexed user, address indexed referrer);
    event Comment(address indexed token, address indexed author, uint256 indexed id, string text);
    event Herald(address indexed who);

    constructor(address _owner, address _minter) ERC1155("") Ownable(_owner) { minter = _minter; }

    function setMinter(address m) external onlyOwner { minter = m; }

    // ------------------------------------------------------------------ referrals
    function register(address referrer) external {
        require(referrer != address(0) && referrer != msg.sender, "Social: bad referrer");
        require(referrerOf[msg.sender] == address(0), "Social: already linked");
        require(referrerOf[referrer] != msg.sender, "Social: loop");
        referrerOf[msg.sender] = referrer;
        refCount[referrer]++;
        referees.push(msg.sender);
        emit Referred(msg.sender, referrer);
    }

    function referralCount() external view returns (uint256) { return referees.length; }

    /// @notice Referral pairs [start, start+n): (user, referrer).
    function referrals(uint256 start, uint256 n) external view returns (address[] memory users, address[] memory refs) {
        uint256 len = referees.length;
        if (start >= len) return (new address[](0), new address[](0));
        if (n > len - start) n = len - start;
        users = new address[](n);
        refs = new address[](n);
        for (uint256 i; i < n; i++) { users[i] = referees[start + i]; refs[i] = referrerOf[users[i]]; }
    }

    // ------------------------------------------------------------------ comments
    function comment(address token, string calldata text) external {
        uint256 len = bytes(text).length;
        require(len > 0 && len <= 280, "Social: 1-280 characters");
        require(block.timestamp >= lastComment[msg.sender] + COMMENT_GAP, "Social: slow down");
        lastComment[msg.sender] = block.timestamp;
        emit Comment(token, msg.sender, ++commentCount, text);
    }

    // ------------------------------------------------------------------ Royal Herald badge
    function awardHerald(address[] calldata to) external {
        require(msg.sender == minter || msg.sender == owner(), "Social: not minter");
        for (uint256 i; i < to.length; i++) {
            if (balanceOf(to[i], HERALD) == 0) { _mint(to[i], HERALD, 1, ""); emit Herald(to[i]); }
        }
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        require(from == address(0), "Social: soulbound");
        super._update(from, to, ids, values);
    }

    function setApprovalForAll(address, bool) public pure override { revert("Social: soulbound"); }

    function uri(uint256) public pure override returns (string memory) {
        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 80"><circle cx="32" cy="32" r="30" fill="#2D6A4F"/>',
            '<circle cx="32" cy="32" r="25" fill="none" stroke="#FFF8EE" stroke-opacity=".5" stroke-width="1.5"/>',
            '<path d="M20 28h6l14-8v24l-14-8h-6zM26 36l3 9" fill="none" stroke="#FFF8EE" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"/>',
            '<path d="M24 10l2.5-6 3.5 4 2-5 2 5 3.5-4 2.5 6z" fill="#E7B73C"/>',
            '<text x="32" y="74" text-anchor="middle" font-family="Georgia,serif" font-size="7.5" fill="#1B1A2E">Royal Herald</text></svg>');
        string memory json = string.concat('{"name":"CavFi \\u00b7 Royal Herald","description":"Invited people who became CavFi traders. Soulbound.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)), '"}');
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
