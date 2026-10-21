// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IWNative {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @title CavFi single-token staking: stake KingS, DOGE, USDT or USDC and earn KingS
/// @notice Same funded, per-second reward stream as KingFarm, with two additions:
///         1. The reward token itself (KingS) can be staked. Staked KingS is tracked as
///            principal and is never used to pay rewards; rewards only come from the funded budget.
///         2. Native DOGE can be staked and unstaked directly; it is held as WDOGE inside.
contract KingStake is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct PoolInfo {
        IERC20 token;
        uint256 allocPoint;
        uint256 lastRewardTime;
        uint256 accRewardPerShare; // scaled by ACC
        uint256 totalStaked;
    }

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    uint256 private constant ACC = 1e18;

    IERC20 public immutable rewardToken;
    address public immutable wnative;
    uint256 public rewardPerSecond;
    uint256 public endTime;
    uint256 public totalAllocPoint;

    uint256 public totalAccrued;
    uint256 public totalPaid;
    /// @notice KingS that users have staked (principal). Never available for rewards.
    uint256 public stakedReward;

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(address => bool) public isPool;

    event PoolAdded(uint256 indexed pid, address indexed token, uint256 allocPoint);
    event PoolSet(uint256 indexed pid, uint256 allocPoint);
    event Funded(uint256 amount, uint256 rewardPerSecond, uint256 endTime);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event UnallocatedRecovered(address indexed to, uint256 amount);

    constructor(IERC20 _rewardToken, address _wnative, address _owner) Ownable(_owner) {
        rewardToken = _rewardToken;
        wnative = _wnative;
    }

    receive() external payable {
        require(msg.sender == wnative, "KingStake: ONLY_WNATIVE");
    }

    /* ---------------- views ---------------- */

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    /// @notice KingS held for rewards (balance minus staked KingS principal)
    function rewardBalance() public view returns (uint256) {
        uint256 bal = rewardToken.balanceOf(address(this));
        return bal > stakedReward ? bal - stakedReward : 0;
    }

    function _poolReward(PoolInfo storage p) internal view returns (uint256) {
        uint256 to = block.timestamp < endTime ? block.timestamp : endTime;
        if (to <= p.lastRewardTime || totalAllocPoint == 0 || p.allocPoint == 0) return 0;
        return (to - p.lastRewardTime) * rewardPerSecond * p.allocPoint / totalAllocPoint;
    }

    function pendingReward(uint256 pid, address user) external view returns (uint256) {
        PoolInfo storage p = poolInfo[pid];
        UserInfo storage u = userInfo[pid][user];
        uint256 acc = p.accRewardPerShare;
        if (block.timestamp > p.lastRewardTime && p.totalStaked > 0) {
            acc += _poolReward(p) * ACC / p.totalStaked;
        }
        return u.amount * acc / ACC - u.rewardDebt;
    }

    function poolRewardPerSecond(uint256 pid) external view returns (uint256) {
        if (block.timestamp >= endTime || totalAllocPoint == 0) return 0;
        return rewardPerSecond * poolInfo[pid].allocPoint / totalAllocPoint;
    }

    function unallocated() public view returns (uint256) {
        uint256 future = endTime > block.timestamp ? (endTime - block.timestamp) * rewardPerSecond : 0;
        uint256 owed = totalAccrued - totalPaid + future;
        uint256 bal = rewardBalance();
        return bal > owed ? bal - owed : 0;
    }

    /* ---------------- pool upkeep ---------------- */

    function massUpdatePools() public {
        for (uint256 i; i < poolInfo.length; i++) updatePool(i);
    }

    function updatePool(uint256 pid) public {
        PoolInfo storage p = poolInfo[pid];
        if (block.timestamp <= p.lastRewardTime) return;
        if (p.totalStaked == 0) {
            p.lastRewardTime = block.timestamp;
            return;
        }
        uint256 r = _poolReward(p);
        if (r > 0) {
            p.accRewardPerShare += r * ACC / p.totalStaked;
            totalAccrued += r;
        }
        p.lastRewardTime = block.timestamp;
    }

    /* ---------------- owner ---------------- */

    function add(uint256 allocPoint, IERC20 token) external onlyOwner {
        require(!isPool[address(token)], "KingStake: POOL_EXISTS");
        massUpdatePools();
        totalAllocPoint += allocPoint;
        poolInfo.push(PoolInfo(token, allocPoint, block.timestamp, 0, 0));
        isPool[address(token)] = true;
        emit PoolAdded(poolInfo.length - 1, address(token), allocPoint);
    }

    function set(uint256 pid, uint256 allocPoint) external onlyOwner {
        massUpdatePools();
        totalAllocPoint = totalAllocPoint - poolInfo[pid].allocPoint + allocPoint;
        poolInfo[pid].allocPoint = allocPoint;
        emit PoolSet(pid, allocPoint);
    }

    function fund(uint256 amount, uint256 duration) external onlyOwner {
        require(duration > 0 && duration <= 365 days, "KingStake: DURATION");
        massUpdatePools();
        uint256 left = endTime > block.timestamp ? (endTime - block.timestamp) * rewardPerSecond : 0;
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        rewardPerSecond = (left + amount) / duration;
        endTime = block.timestamp + duration;
        emit Funded(amount, rewardPerSecond, endTime);
    }

    function recoverUnallocated(address to) external onlyOwner {
        massUpdatePools();
        uint256 amt = unallocated();
        rewardToken.safeTransfer(to, amt);
        emit UnallocatedRecovered(to, amt);
    }

    /* ---------------- internals ---------------- */

    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        uint256 bal = rewardBalance();
        if (amount > bal) amount = bal;
        totalPaid += amount;
        rewardToken.safeTransfer(to, amount);
    }

    function _harvest(uint256 pid, address user) internal {
        PoolInfo storage p = poolInfo[pid];
        UserInfo storage u = userInfo[pid][user];
        if (u.amount > 0) {
            uint256 paid = u.amount * p.accRewardPerShare / ACC - u.rewardDebt;
            if (paid > 0) {
                _pay(user, paid);
                emit Harvest(user, pid, paid);
            }
        }
    }

    function _credit(uint256 pid, address user, uint256 received) internal {
        PoolInfo storage p = poolInfo[pid];
        userInfo[pid][user].amount += received;
        p.totalStaked += received;
        if (address(p.token) == address(rewardToken)) stakedReward += received;
    }

    function _debit(uint256 pid, address user, uint256 amount) internal {
        PoolInfo storage p = poolInfo[pid];
        userInfo[pid][user].amount -= amount;
        p.totalStaked -= amount;
        if (address(p.token) == address(rewardToken)) stakedReward -= amount;
    }

    function _sync(uint256 pid, address user) internal {
        UserInfo storage u = userInfo[pid][user];
        u.rewardDebt = u.amount * poolInfo[pid].accRewardPerShare / ACC;
    }

    /* ---------------- users ---------------- */

    function deposit(uint256 pid, uint256 amount) external nonReentrant {
        PoolInfo storage p = poolInfo[pid];
        updatePool(pid);
        _harvest(pid, msg.sender);
        if (amount > 0) {
            uint256 before = p.token.balanceOf(address(this));
            p.token.safeTransferFrom(msg.sender, address(this), amount);
            _credit(pid, msg.sender, p.token.balanceOf(address(this)) - before);
        }
        _sync(pid, msg.sender);
        emit Deposit(msg.sender, pid, amount);
    }

    /// @notice Stake native DOGE into the WDOGE pool in one transaction.
    function depositNative(uint256 pid) external payable nonReentrant {
        require(address(poolInfo[pid].token) == wnative, "KingStake: NOT_NATIVE_POOL");
        updatePool(pid);
        _harvest(pid, msg.sender);
        if (msg.value > 0) {
            IWNative(wnative).deposit{value: msg.value}();
            _credit(pid, msg.sender, msg.value);
        }
        _sync(pid, msg.sender);
        emit Deposit(msg.sender, pid, msg.value);
    }

    function withdraw(uint256 pid, uint256 amount) external nonReentrant {
        require(userInfo[pid][msg.sender].amount >= amount, "KingStake: AMOUNT");
        updatePool(pid);
        _harvest(pid, msg.sender);
        if (amount > 0) {
            _debit(pid, msg.sender, amount);
            poolInfo[pid].token.safeTransfer(msg.sender, amount);
        }
        _sync(pid, msg.sender);
        emit Withdraw(msg.sender, pid, amount);
    }

    /// @notice Unstake from the WDOGE pool and receive native DOGE.
    function withdrawNative(uint256 pid, uint256 amount) external nonReentrant {
        require(address(poolInfo[pid].token) == wnative, "KingStake: NOT_NATIVE_POOL");
        require(userInfo[pid][msg.sender].amount >= amount, "KingStake: AMOUNT");
        updatePool(pid);
        _harvest(pid, msg.sender);
        if (amount > 0) {
            _debit(pid, msg.sender, amount);
            IWNative(wnative).withdraw(amount);
            (bool ok,) = msg.sender.call{value: amount}("");
            require(ok, "KingStake: DOGE_SEND");
        }
        _sync(pid, msg.sender);
        emit Withdraw(msg.sender, pid, amount);
    }

    function harvest(uint256 pid) external nonReentrant {
        updatePool(pid);
        _harvest(pid, msg.sender);
        _sync(pid, msg.sender);
    }

    /// @notice Take your tokens back immediately and give up unharvested rewards.
    function emergencyWithdraw(uint256 pid) external nonReentrant {
        PoolInfo storage p = poolInfo[pid];
        UserInfo storage u = userInfo[pid][msg.sender];
        uint256 amount = u.amount;
        totalAccrued -= amount * p.accRewardPerShare / ACC - u.rewardDebt;
        _debit(pid, msg.sender, amount);
        u.rewardDebt = 0;
        p.token.safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, pid, amount);
    }
}
