// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title KingSwap farm: stake KingSwap LP tokens, earn KingS
/// @notice MasterChef-style accounting with a funded budget instead of minting.
///         The owner deposits a fixed amount of KingS for a fixed duration; the farm
///         streams it per second to staked pools by weight (allocPoint). The farm can
///         never promise more KingS than it holds.
contract KingFarm is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct PoolInfo {
        IERC20 lpToken;
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
    uint256 public rewardPerSecond;
    uint256 public endTime;
    uint256 public totalAllocPoint;

    /// @notice KingS assigned to pools so far, and KingS paid out so far (for solvency checks)
    uint256 public totalAccrued;
    uint256 public totalPaid;

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(address => bool) public isPool;

    event PoolAdded(uint256 indexed pid, address indexed lpToken, uint256 allocPoint);
    event PoolSet(uint256 indexed pid, uint256 allocPoint);
    event Funded(uint256 amount, uint256 rewardPerSecond, uint256 endTime);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event UnallocatedRecovered(address indexed to, uint256 amount);

    constructor(IERC20 _rewardToken, address _owner) Ownable(_owner) {
        rewardToken = _rewardToken;
    }

    /* ---------------- views ---------------- */

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function _poolReward(PoolInfo storage p) internal view returns (uint256) {
        uint256 to = block.timestamp < endTime ? block.timestamp : endTime;
        if (to <= p.lastRewardTime || totalAllocPoint == 0 || p.allocPoint == 0) return 0;
        return (to - p.lastRewardTime) * rewardPerSecond * p.allocPoint / totalAllocPoint;
    }

    /// @notice KingS a user can harvest right now
    function pendingReward(uint256 pid, address user) external view returns (uint256) {
        PoolInfo storage p = poolInfo[pid];
        UserInfo storage u = userInfo[pid][user];
        uint256 acc = p.accRewardPerShare;
        if (block.timestamp > p.lastRewardTime && p.totalStaked > 0) {
            acc += _poolReward(p) * ACC / p.totalStaked;
        }
        return u.amount * acc / ACC - u.rewardDebt;
    }

    /// @notice KingS per second currently flowing to one pool (0 after endTime)
    function poolRewardPerSecond(uint256 pid) external view returns (uint256) {
        if (block.timestamp >= endTime || totalAllocPoint == 0) return 0;
        return rewardPerSecond * poolInfo[pid].allocPoint / totalAllocPoint;
    }

    /// @notice KingS held by the farm that is not owed to anyone and not scheduled for future rewards.
    ///         Comes from periods when a pool had nothing staked, plus rounding dust.
    function unallocated() public view returns (uint256) {
        uint256 future = endTime > block.timestamp ? (endTime - block.timestamp) * rewardPerSecond : 0;
        uint256 owed = totalAccrued - totalPaid + future;
        uint256 bal = rewardToken.balanceOf(address(this));
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

    function add(uint256 allocPoint, IERC20 lpToken) external onlyOwner {
        require(!isPool[address(lpToken)], "KingFarm: POOL_EXISTS");
        require(address(lpToken) != address(rewardToken), "KingFarm: REWARD_TOKEN");
        massUpdatePools();
        totalAllocPoint += allocPoint;
        poolInfo.push(PoolInfo(lpToken, allocPoint, block.timestamp, 0, 0));
        isPool[address(lpToken)] = true;
        emit PoolAdded(poolInfo.length - 1, address(lpToken), allocPoint);
    }

    function set(uint256 pid, uint256 allocPoint) external onlyOwner {
        massUpdatePools();
        totalAllocPoint = totalAllocPoint - poolInfo[pid].allocPoint + allocPoint;
        poolInfo[pid].allocPoint = allocPoint;
        emit PoolSet(pid, allocPoint);
    }

    /// @notice Add `amount` KingS and (re)start the reward stream to run for `duration` seconds.
    ///         Rewards not yet streamed from a previous funding roll into the new period.
    function fund(uint256 amount, uint256 duration) external onlyOwner {
        require(duration > 0 && duration <= 365 days, "KingFarm: DURATION");
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

    /* ---------------- users ---------------- */

    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        uint256 bal = rewardToken.balanceOf(address(this));
        if (amount > bal) amount = bal;
        totalPaid += amount;
        rewardToken.safeTransfer(to, amount);
    }

    function _harvest(uint256 pid, address user) internal returns (uint256 paid) {
        PoolInfo storage p = poolInfo[pid];
        UserInfo storage u = userInfo[pid][user];
        if (u.amount > 0) {
            paid = u.amount * p.accRewardPerShare / ACC - u.rewardDebt;
            if (paid > 0) {
                _pay(user, paid);
                emit Harvest(user, pid, paid);
            }
        }
    }

    function deposit(uint256 pid, uint256 amount) external nonReentrant {
        PoolInfo storage p = poolInfo[pid];
        UserInfo storage u = userInfo[pid][msg.sender];
        updatePool(pid);
        _harvest(pid, msg.sender);
        if (amount > 0) {
            uint256 before = p.lpToken.balanceOf(address(this));
            p.lpToken.safeTransferFrom(msg.sender, address(this), amount);
            uint256 received = p.lpToken.balanceOf(address(this)) - before;
            u.amount += received;
            p.totalStaked += received;
        }
        u.rewardDebt = u.amount * p.accRewardPerShare / ACC;
        emit Deposit(msg.sender, pid, amount);
    }

    function withdraw(uint256 pid, uint256 amount) external nonReentrant {
        PoolInfo storage p = poolInfo[pid];
        UserInfo storage u = userInfo[pid][msg.sender];
        require(u.amount >= amount, "KingFarm: AMOUNT");
        updatePool(pid);
        _harvest(pid, msg.sender);
        if (amount > 0) {
            u.amount -= amount;
            p.totalStaked -= amount;
            p.lpToken.safeTransfer(msg.sender, amount);
        }
        u.rewardDebt = u.amount * p.accRewardPerShare / ACC;
        emit Withdraw(msg.sender, pid, amount);
    }

    function harvest(uint256 pid) external nonReentrant {
        updatePool(pid);
        _harvest(pid, msg.sender);
        UserInfo storage u = userInfo[pid][msg.sender];
        u.rewardDebt = u.amount * poolInfo[pid].accRewardPerShare / ACC;
    }

    /// @notice Take your LP back immediately and give up unharvested rewards.
    function emergencyWithdraw(uint256 pid) external nonReentrant {
        PoolInfo storage p = poolInfo[pid];
        UserInfo storage u = userInfo[pid][msg.sender];
        uint256 amount = u.amount;
        // rewards given up here go back to the unallocated pot the owner can recover
        uint256 forfeited = amount * p.accRewardPerShare / ACC - u.rewardDebt;
        totalAccrued -= forfeited;
        u.amount = 0;
        u.rewardDebt = 0;
        p.totalStaked -= amount;
        p.lpToken.safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, pid, amount);
    }
}
