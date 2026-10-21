// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IVoteFarm {
    function poolLength() external view returns (uint256);
    function poolInfo(uint256) external view returns (address lpToken, uint256 allocPoint, uint256 lastRewardTime, uint256 accRewardPerShare, uint256 totalStaked);
    function add(uint256 allocPoint, IERC20 lpToken) external;
    function set(uint256 pid, uint256 allocPoint) external;
    function fund(uint256 amount, uint256 duration) external;
    function recoverUnallocated(address to) external;
    function transferOwnership(address newOwner) external;
}

/// @title CavFi reward voting
/// @notice Lock KingS to get votes (1 KingS = 1 vote) and split them across KingFarm pools.
///         Once per epoch anyone may call `applyVotes()`: every pool then gets a small base weight
///         plus a share of VOTE_POINTS in proportion to its votes. Unlock any time; your votes
///         shrink with your lock immediately, so the same KingS can never vote twice.
///         This contract owns the farm; its own owner can add pools and fund rewards, and can
///         hand the farm back, but cannot set pool weights directly.
contract KingVote is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant EPOCH = 7 days;
    uint256 public constant VOTE_POINTS = 1000;
    uint256 public constant MAX_CHOICES = 10;

    IERC20 public immutable kings;
    IVoteFarm public immutable farm;
    uint256 public baseAlloc;     // weight every pool keeps, votes or not
    uint256 public lastApply;
    uint256 public totalLocked;
    uint256 public totalVotes;    // sum of all tallies

    mapping(address => uint256) public locked;
    mapping(uint256 => uint256) public tally;   // pid => votes
    mapping(address => uint256[]) internal choicePids;
    mapping(address => uint256[]) internal choiceBps;

    event Locked(address indexed user, uint256 amount);
    event Unlocked(address indexed user, uint256 amount);
    event Voted(address indexed user, uint256[] pids, uint256[] bps);
    event Applied(uint256 indexed epochStart, uint256 totalVotes);

    constructor(IERC20 _kings, IVoteFarm _farm, address _owner, uint256 _baseAlloc) Ownable(_owner) {
        kings = _kings;
        farm = _farm;
        baseAlloc = _baseAlloc;
    }

    // ------------------------------------------------------------------ voters
    function lock(uint256 amount) external nonReentrant {
        require(amount > 0, "KingVote: ZERO");
        _unweigh(msg.sender);
        kings.safeTransferFrom(msg.sender, address(this), amount);
        locked[msg.sender] += amount;
        totalLocked += amount;
        _weigh(msg.sender);
        emit Locked(msg.sender, amount);
    }

    function unlock(uint256 amount) external nonReentrant {
        require(amount > 0 && amount <= locked[msg.sender], "KingVote: AMOUNT");
        _unweigh(msg.sender);
        locked[msg.sender] -= amount;
        totalLocked -= amount;
        _weigh(msg.sender);
        kings.safeTransfer(msg.sender, amount);
        emit Unlocked(msg.sender, amount);
    }

    /// @param bps share of your votes per pool, in basis points; must add up to 10000 (or pass empty arrays to clear)
    function vote(uint256[] calldata pids, uint256[] calldata bps) external {
        require(pids.length == bps.length && pids.length <= MAX_CHOICES, "KingVote: LENGTH");
        uint256 n = farm.poolLength();
        uint256 sum;
        for (uint256 i; i < pids.length; i++) {
            require(pids[i] < n, "KingVote: POOL");
            for (uint256 j; j < i; j++) require(pids[j] != pids[i], "KingVote: DUPLICATE");
            sum += bps[i];
        }
        require(pids.length == 0 || sum == 10_000, "KingVote: BPS");
        _unweigh(msg.sender);
        choicePids[msg.sender] = pids;
        choiceBps[msg.sender] = bps;
        _weigh(msg.sender);
        emit Voted(msg.sender, pids, bps);
    }

    function _weigh(address u) internal {
        uint256 p = locked[u];
        uint256[] storage ps = choicePids[u];
        uint256[] storage bs = choiceBps[u];
        for (uint256 i; i < ps.length; i++) { uint256 v = p * bs[i] / 10_000; tally[ps[i]] += v; totalVotes += v; }
    }

    function _unweigh(address u) internal {
        uint256 p = locked[u];
        uint256[] storage ps = choicePids[u];
        uint256[] storage bs = choiceBps[u];
        for (uint256 i; i < ps.length; i++) { uint256 v = p * bs[i] / 10_000; tally[ps[i]] -= v; totalVotes -= v; }
    }

    // ------------------------------------------------------------------ apply
    function nextApply() public view returns (uint256) { return lastApply == 0 ? 0 : lastApply + EPOCH; }

    /// @notice Push the current votes into the farm. Anyone can call it once per epoch.
    function applyVotes() external nonReentrant {
        require(block.timestamp >= nextApply(), "KingVote: TOO_SOON");
        lastApply = block.timestamp;
        if (totalVotes > 0) {
            uint256 n = farm.poolLength();
            for (uint256 pid; pid < n; pid++) farm.set(pid, baseAlloc + tally[pid] * VOTE_POINTS / totalVotes);
        }
        emit Applied(block.timestamp, totalVotes);
    }

    // ------------------------------------------------------------------ admin (pools and funding only)
    function addFarmPool(IERC20 lpToken) external onlyOwner { farm.add(baseAlloc, lpToken); }

    /// @notice Pulls `amount` KingS from the owner and funds the farm with it.
    function fundFarm(uint256 amount, uint256 duration) external onlyOwner nonReentrant {
        uint256 b0 = kings.balanceOf(address(this));
        kings.safeTransferFrom(msg.sender, address(this), amount);
        kings.forceApprove(address(farm), amount);
        farm.fund(amount, duration);
        require(kings.balanceOf(address(this)) == b0, "KingVote: FUND");
    }

    function recoverFarm(address to) external onlyOwner { farm.recoverUnallocated(to); }

    function setBaseAlloc(uint256 v) external onlyOwner { require(v <= VOTE_POINTS, "KingVote: BASE"); baseAlloc = v; }

    /// @notice Give the farm back to a normal owner (ends voting control).
    function releaseFarm(address newOwner) external onlyOwner { farm.transferOwnership(newOwner); }

    // ------------------------------------------------------------------ views
    function choicesOf(address u) external view returns (uint256[] memory pids, uint256[] memory bps) { return (choicePids[u], choiceBps[u]); }

    function tallies() external view returns (uint256[] memory out) {
        uint256 n = farm.poolLength();
        out = new uint256[](n);
        for (uint256 i; i < n; i++) out[i] = tally[i];
    }
}
