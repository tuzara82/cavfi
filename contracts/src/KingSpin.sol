// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CavFi Royal Spin: one free spin of the wheel per wallet per UTC day, every spin wins KingS
/// @notice Same fairness as CavFi Games: the house (the CavFi bot) commits a hash chain, anchor = keccak^N(secret).
///         A spin joins the 30-second round open when it lands; once that round has closed the house reveals its
///         seed, which must hash forward to the previous one, and every spin of the round lands on
///         segment = keccak256(seed, spinId) % 20. Rounds are revealed strictly in order; if the house is more than
///         an hour late a spin can be claimed at the top prize; while it is 10 minutes behind, spins are paused.
///         The 20 segments, in prize units (1 unit = `unit` KingS): 6 x 5, 6 x 10, 4 x 25, 2 x 50, 1 x 100, 1 x 500.
contract KingSpin is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant ROUND = 30;
    uint256 public constant OFFLINE = 10 minutes;
    uint256 public constant TIMEOUT = 1 hours;
    uint256 public constant MAX_SPINS = 60;     // per round
    uint256 public constant VERSION = 3;        // the bot's chain derivation for this contract (as Games v2+)
    uint256 public constant TOP = 500;          // the jackpot, in units

    enum Status { None, Pending, Paid, TimeoutPaid }

    struct Spin {
        address player;
        uint32 round;
        uint32 day;
        uint8 segment;
        Status status;
        uint96 prize;
        uint40 at;
    }

    IERC20 public immutable kings;
    address public house;
    uint256 public unit = 100 ether;            // 1 prize unit in KingS
    uint256 public reserved;                    // the top prize of every pending spin
    uint256 public anchors;
    uint256 public lastRound;
    bytes32 public lastSeed;
    uint256 public chainLeft;

    Spin[] internal spins;
    mapping(uint256 => uint256[]) internal roundSpins;
    mapping(uint256 => bytes32) public roundSeed;
    uint256[] internal queue;
    uint256 public head;
    mapping(address => uint32) public lastDay;  // UTC day of a wallet's last spin, + 1 (0 = never)
    mapping(address => uint256[]) internal byPlayer;
    uint256 public totalPaid;

    event Spun(uint256 indexed id, address indexed player, uint256 round);
    event Landed(uint256 indexed id, address indexed player, uint8 segment, uint256 prize);
    event Revealed(uint256 indexed round, bytes32 seed, uint256 spins);
    event Anchored(uint256 indexed n, bytes32 anchor, uint256 round, uint256 length);
    event Funded(address indexed from, uint256 amount);

    constructor(address owner_, address house_, IERC20 kings_) Ownable(owner_) {
        house = house_;
        kings = kings_;
    }

    modifier onlyHouse() {
        require(msg.sender == house || msg.sender == owner(), "Spin: not house");
        _;
    }

    // ------------------------------------------------------------- admin
    function setHouse(address h) external onlyOwner { house = h; }

    function setUnit(uint256 u) external onlyOwner {
        require(u > 0 && reserved == 0, "Spin: unit");
        unit = u;
    }

    function fund(uint256 amount) external {
        kings.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    function withdraw(uint256 amount, address to) external onlyOwner {
        require(amount <= free(), "Spin: reserved");
        kings.safeTransfer(to, amount);
    }

    function setAnchor(bytes32 anchor, uint256 length) external onlyHouse {
        require(head == queue.length, "Spin: rounds pending");
        require(anchor != bytes32(0) && length > 0, "Spin: anchor");
        lastRound = currentRound();
        lastSeed = anchor;
        chainLeft = length;
        anchors++;
        emit Anchored(anchors, anchor, lastRound, length);
    }

    // ------------------------------------------------------------- views
    function segmentUnits(uint256 i) public pure returns (uint256) {
        uint16[20] memory w = [uint16(5), 10, 25, 5, 50, 10, 5, 100, 10, 25, 5, 500, 10, 25, 5, 50, 10, 5, 25, 10];
        return w[i];
    }

    function currentRound() public view returns (uint256) { return block.timestamp / ROUND; }
    function today() public view returns (uint32) { return uint32(block.timestamp / 1 days); }

    function free() public view returns (uint256) {
        uint256 b = kings.balanceOf(address(this));
        return b > reserved ? b - reserved : 0;
    }

    function houseOnline() public view returns (bool) {
        if (lastSeed == bytes32(0)) return false;
        if (head < queue.length && block.timestamp > (queue[head] + 1) * ROUND + OFFLINE) return false;
        return chainLeft > currentRound() - lastRound + 1;
    }

    function canSpin(address who) public view returns (bool) {
        return lastDay[who] != today() + 1;
    }

    // ------------------------------------------------------------- play
    function spin() external nonReentrant returns (uint256 id) {
        require(houseOnline(), "Spin: house offline");
        require(canSpin(msg.sender), "Spin: one spin a day");
        uint256 top = TOP * unit;
        require(free() >= top, "Spin: prize fund empty");
        uint256 r = currentRound();
        require(r > lastRound, "Spin: round");
        uint256[] storage rs = roundSpins[r];
        require(rs.length < MAX_SPINS, "Spin: round full");
        if (rs.length == 0) queue.push(r);
        lastDay[msg.sender] = today() + 1;
        id = spins.length;
        spins.push(Spin(msg.sender, uint32(r), today(), 0, Status.Pending, uint96(top), uint40(block.timestamp)));
        rs.push(id);
        byPlayer[msg.sender].push(id);
        reserved += top;
        emit Spun(id, msg.sender, r);
    }

    function reveal(bytes32 seed) external nonReentrant {
        require(head < queue.length, "Spin: nothing to reveal");
        uint256 r = queue[head];
        require(block.timestamp >= (r + 1) * ROUND, "Spin: round open");
        uint256 k = r - lastRound;
        require(k < chainLeft, "Spin: chain used up");
        bytes32 h = seed;
        for (uint256 i; i < k; i++) h = keccak256(abi.encodePacked(h));
        require(h == lastSeed, "Spin: bad seed");
        lastRound = r;
        lastSeed = seed;
        chainLeft -= k;
        roundSeed[r] = seed;
        head++;
        uint256[] storage rs = roundSpins[r];
        for (uint256 i; i < rs.length; i++) {
            Spin storage s = spins[rs[i]];
            if (s.status != Status.Pending) continue;
            uint8 seg = uint8(uint256(keccak256(abi.encodePacked(seed, rs[i]))) % 20);
            uint256 prize = segmentUnits(seg) * unit;
            reserved -= s.prize;
            s.segment = seg;
            s.prize = uint96(prize);
            s.status = Status.Paid;
            totalPaid += prize;
            kings.safeTransfer(s.player, prize);
            emit Landed(rs[i], s.player, seg, prize);
        }
        emit Revealed(r, seed, rs.length);
    }

    function claimTimeout(uint256 id) external nonReentrant {
        Spin storage s = spins[id];
        require(s.status == Status.Pending, "Spin: not pending");
        require(roundSeed[s.round] == bytes32(0), "Spin: revealed");
        require(block.timestamp > (uint256(s.round) + 1) * ROUND + TIMEOUT, "Spin: not late");
        s.status = Status.TimeoutPaid;
        reserved -= s.prize;
        totalPaid += s.prize;
        kings.safeTransfer(s.player, s.prize);
        emit Landed(id, s.player, 255, s.prize);
    }

    function count() external view returns (uint256) { return spins.length; }
    function get(uint256 id) external view returns (Spin memory) { return spins[id]; }
    function pendingRounds() external view returns (uint256[] memory out) {
        out = new uint256[](queue.length - head);
        for (uint256 i; i < out.length; i++) out[i] = queue[head + i];
    }

    function page(uint256 start, uint256 n) external view returns (uint256[] memory ids, Spin[] memory items) {
        uint256 len = spins.length;
        if (start >= len) return (new uint256[](0), new Spin[](0));
        if (n > len - start) n = len - start;
        ids = new uint256[](n);
        items = new Spin[](n);
        for (uint256 i; i < n; i++) { ids[i] = len - 1 - start - i; items[i] = spins[ids[i]]; }
    }

    function pageOf(address who, uint256 start, uint256 n) external view returns (uint256[] memory ids, Spin[] memory items) {
        uint256[] storage all = byPlayer[who];
        uint256 len = all.length;
        if (start >= len) return (new uint256[](0), new Spin[](0));
        if (n > len - start) n = len - start;
        ids = new uint256[](n);
        items = new Spin[](n);
        for (uint256 i; i < n; i++) { ids[i] = all[len - 1 - start - i]; items[i] = spins[ids[i]]; }
    }
}
