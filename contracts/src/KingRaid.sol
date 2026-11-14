// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CavFi Raid: a co-op boss everyone on CavFi fights together
/// @notice A raid has a boss with hit points. Every action a player takes on CavFi (a spin, a game, an Arena stake,
///         a solved riddle, a gm, a swap...) deals damage: the CavFi bot reads those transactions from the chain and
///         records the damage here in batches (attester). When the boss hits 0 HP before the raid ends, it is
///         defeated and every player who dealt damage can claim a share of the KingS prize in proportion to the
///         damage they dealt. The player who lands the final blow is recorded. If the raid ends with the boss still
///         standing, nobody wins and the owner can take the prize back.
contract KingRaid is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_PLAYERS = 2000;   // per raid

    struct Raid {
        string title;
        uint64 start;
        uint64 end;
        uint64 defeatedAt;
        uint128 maxHp;
        uint128 hp;
        uint256 prize;
        uint256 claimed;
        uint256 totalDamage;
        address finalBlow;
    }

    IERC20 public immutable kings;
    mapping(address => bool) public attester;
    Raid[] internal raids;
    mapping(uint256 => mapping(address => uint256)) public damageOf;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;
    mapping(uint256 => address[]) internal players;

    event RaidCreated(uint256 indexed id, string title, uint64 start, uint64 end, uint128 hp, uint256 prize);
    event Hit(uint256 indexed id, address indexed player, uint256 damage, uint128 hpLeft);
    event Defeated(uint256 indexed id, address indexed finalBlow, uint64 at);
    event Claimed(uint256 indexed id, address indexed player, uint256 amount);
    event Attester(address indexed who, bool on);

    constructor(address owner_, IERC20 kings_) Ownable(owner_) {
        kings = kings_;
    }

    function setAttester(address who, bool on) external onlyOwner {
        attester[who] = on;
        emit Attester(who, on);
    }

    /// @notice Opens a raid and pulls its prize (KingS) from the owner.
    function create(string calldata title, uint64 start, uint64 end, uint128 hp, uint256 prize) external onlyOwner returns (uint256 id) {
        require(end > start && end > block.timestamp && hp > 0, "Raid: params");
        id = raids.length;
        raids.push(Raid(title, start, end, 0, hp, hp, prize, 0, 0, address(0)));
        if (prize > 0) kings.safeTransferFrom(msg.sender, address(this), prize);
        emit RaidCreated(id, title, start, end, hp, prize);
    }

    /// @notice Records damage for a batch of players (the bot, after reading their transactions from the chain).
    function hit(uint256 id, address[] calldata who, uint256[] calldata dmg) external {
        require(attester[msg.sender], "Raid: not attester");
        require(who.length == dmg.length, "Raid: length");
        Raid storage r = raids[id];
        require(block.timestamp >= r.start && block.timestamp < r.end && r.hp > 0, "Raid: not running");
        for (uint256 i; i < who.length && r.hp > 0; i++) {
            uint256 d = dmg[i];
            if (d == 0 || who[i] == address(0)) continue;
            if (d > r.hp) d = r.hp;
            if (damageOf[id][who[i]] == 0) {
                require(players[id].length < MAX_PLAYERS, "Raid: full");
                players[id].push(who[i]);
            }
            damageOf[id][who[i]] += d;
            r.totalDamage += d;
            r.hp -= uint128(d);
            emit Hit(id, who[i], d, r.hp);
            if (r.hp == 0) {
                r.defeatedAt = uint64(block.timestamp);
                r.finalBlow = who[i];
                emit Defeated(id, who[i], uint64(block.timestamp));
            }
        }
    }

    /// @notice A player's share of a defeated boss's prize, in proportion to the damage they dealt.
    function claimable(uint256 id, address who) public view returns (uint256) {
        Raid storage r = raids[id];
        if (r.defeatedAt == 0 || hasClaimed[id][who] || r.totalDamage == 0) return 0;
        return r.prize * damageOf[id][who] / r.totalDamage;
    }

    function claim(uint256 id) external nonReentrant returns (uint256 amount) {
        amount = claimable(id, msg.sender);
        require(amount > 0, "Raid: nothing to claim");
        hasClaimed[id][msg.sender] = true;
        raids[id].claimed += amount;
        kings.safeTransfer(msg.sender, amount);
        emit Claimed(id, msg.sender, amount);
    }

    /// @notice After a raid ended with the boss still standing, the owner takes the prize back.
    function reclaim(uint256 id) external onlyOwner {
        Raid storage r = raids[id];
        require(block.timestamp >= r.end && r.defeatedAt == 0, "Raid: running or won");
        uint256 left = r.prize - r.claimed;
        require(left > 0, "Raid: nothing left");
        r.claimed = r.prize;
        kings.safeTransfer(owner(), left);
    }

    // ------------------------------------------------------------- views
    function count() external view returns (uint256) { return raids.length; }
    function get(uint256 id) external view returns (Raid memory) { return raids[id]; }
    function playerCount(uint256 id) external view returns (uint256) { return players[id].length; }

    /// @notice Players of a raid with their damage, from `start`, at most `n`.
    function page(uint256 id, uint256 start, uint256 n) external view returns (address[] memory who, uint256[] memory dmg) {
        address[] storage all = players[id];
        if (start >= all.length) return (new address[](0), new uint256[](0));
        if (n > all.length - start) n = all.length - start;
        who = new address[](n);
        dmg = new uint256[](n);
        for (uint256 i; i < n; i++) { who[i] = all[start + i]; dmg[i] = damageOf[id][who[i]]; }
    }
}
