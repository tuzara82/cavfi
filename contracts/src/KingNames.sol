// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @title CavFi Names (.cav)
/// @notice Human-readable names like `borislav.cav` for DogeOS addresses. Each name is an NFT owned forever
///         (no renewals). Price depends on length: shorter names cost more. A holder can pick one of their
///         names as their primary name; the site shows it instead of the address.
/// @dev Names are lowercase a-z, 0-9 and '-', 3 to 32 characters, no leading or trailing '-'.
///      tokenId = uint256(keccak256(label)).
contract KingNames is ERC721Enumerable, Ownable {
    uint256 public price3; // exactly 3 characters
    uint256 public price4; // exactly 4 characters
    uint256 public price5; // 5 or more
    address public feeTo;
    uint256 public totalNames;

    mapping(uint256 => string) public labelOf;
    mapping(address => uint256) private _primary;

    event Registered(address indexed owner, uint256 indexed id, string label, uint256 paid);
    event PrimarySet(address indexed owner, uint256 indexed id);
    event PricesSet(uint256 p3, uint256 p4, uint256 p5);

    error BadName();
    error Taken();
    error WrongPayment();
    error NotOwner();

    constructor(address owner_, uint256 p3, uint256 p4, uint256 p5) ERC721("CavFi Names", "CAV") Ownable(owner_) {
        (price3, price4, price5) = (p3, p4, p5);
        feeTo = owner_;
    }

    // ---------------------------------------------------------------- helpers

    function idOf(string memory label) public pure returns (uint256) {
        return uint256(keccak256(bytes(label)));
    }

    function valid(string memory label) public pure returns (bool) {
        bytes memory b = bytes(label);
        if (b.length < 3 || b.length > 32) return false;
        if (b[0] == "-" || b[b.length - 1] == "-") return false;
        for (uint256 i; i < b.length; i++) {
            bytes1 c = b[i];
            bool ok = (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "-";
            if (!ok) return false;
        }
        return true;
    }

    function priceOf(string memory label) public view returns (uint256) {
        uint256 n = bytes(label).length;
        return n == 3 ? price3 : n == 4 ? price4 : price5;
    }

    /// @notice Owner of `label` (address(0) if free).
    function resolve(string memory label) external view returns (address) {
        return _ownerOf(idOf(label));
    }

    function available(string memory label) external view returns (bool) {
        return valid(label) && _ownerOf(idOf(label)) == address(0);
    }

    // ---------------------------------------------------------------- actions

    function register(string calldata label) external payable returns (uint256 id) {
        if (!valid(label)) revert BadName();
        id = idOf(label);
        if (_ownerOf(id) != address(0)) revert Taken();
        uint256 p = priceOf(label);
        if (msg.value != p) revert WrongPayment();
        labelOf[id] = label;
        totalNames++;
        _safeMint(msg.sender, id);
        if (_primary[msg.sender] == 0) {
            _primary[msg.sender] = id;
            emit PrimarySet(msg.sender, id);
        }
        emit Registered(msg.sender, id, label, p);
    }

    function setPrimary(uint256 id) external {
        if (_ownerOf(id) != msg.sender) revert NotOwner();
        _primary[msg.sender] = id;
        emit PrimarySet(msg.sender, id);
    }

    /// @notice The primary name of `who` without the suffix ("" if none, or if they no longer own it).
    function nameOf(address who) public view returns (string memory) {
        uint256 id = _primary[who];
        if (id == 0 || _ownerOf(id) != who) return "";
        return labelOf[id];
    }

    /// @notice Primary names for many addresses at once (for leaderboards and lists).
    function namesOf(address[] calldata who) external view returns (string[] memory out) {
        out = new string[](who.length);
        for (uint256 i; i < who.length; i++) out[i] = nameOf(who[i]);
    }

    // ---------------------------------------------------------------- owner

    function setPrices(uint256 p3, uint256 p4, uint256 p5) external onlyOwner {
        (price3, price4, price5) = (p3, p4, p5);
        emit PricesSet(p3, p4, p5);
    }

    function setFeeTo(address f) external onlyOwner {
        feeTo = f;
    }

    /// Sends registration fees to feeTo.
    function withdraw() external {
        (bool ok,) = feeTo.call{value: address(this).balance}("");
        require(ok, "send");
    }

    /// @notice Labels of all names `who` holds (for the "your names" list).
    function labelsOf(address who) external view returns (string[] memory out, uint256[] memory ids) {
        uint256 n = balanceOf(who);
        out = new string[](n);
        ids = new uint256[](n);
        for (uint256 i; i < n; i++) {
            ids[i] = tokenOfOwnerByIndex(who, i);
            out[i] = labelOf[ids[i]];
        }
    }

    /// @notice The `n` most recently registered names (newest first).
    function recent(uint256 n) external view returns (string[] memory out, address[] memory owners) {
        uint256 total = totalSupply();
        if (n > total) n = total;
        out = new string[](n);
        owners = new address[](n);
        for (uint256 i; i < n; i++) {
            uint256 id = tokenByIndex(total - 1 - i);
            out[i] = labelOf[id];
            owners[i] = _ownerOf(id);
        }
    }

    // ---------------------------------------------------------------- metadata

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        string memory full = string.concat(labelOf[id], ".cav");
        uint256 n = bytes(full).length;
        string memory size = n <= 10 ? "34" : n <= 16 ? "26" : n <= 24 ? "19" : "14";
        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">',
            '<stop offset="0" stop-color="#A3461E"/><stop offset="1" stop-color="#1B1A2E"/></linearGradient></defs>',
            '<rect width="400" height="400" rx="36" fill="url(#g)"/>',
            '<path d="M150 110l13-45 26 24 11-34 11 34 26-24 13 45z" fill="#E7B73C"/>',
            '<text x="200" y="235" text-anchor="middle" font-family="Georgia,serif" font-size="', size, '" fill="#FFF8EE">', full, "</text>",
            '<text x="200" y="350" text-anchor="middle" font-family="monospace" font-size="14" fill="#FFF8EE" fill-opacity=".6">CavFi Names - DogeOS</text></svg>'
        );
        string memory json = string.concat(
            '{"name":"', full, '","description":"A .cav name on CavFi (DogeOS testnet). Yours forever, no renewals.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)), '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
