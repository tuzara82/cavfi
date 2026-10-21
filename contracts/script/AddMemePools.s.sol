// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AddrBook} from "./AddrBook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILaunchList {
    function count() external view returns (uint256);
    function tokens(uint256) external view returns (address);
    struct Launch {
        address creator; uint64 createdAt; bool graduated; uint256 vDoge; uint256 vTok; uint256 realDoge;
        uint256 tokensLeft; uint256 target; address pair; string name; string symbol; string description; string image;
    }
    function info(address) external view returns (Launch memory);
}

interface IVoteAdmin {
    function addFarmPool(IERC20 lpToken) external;
    function fundFarm(uint256 amount, uint256 duration) external;
}

interface IRewards {
    function owner() external view returns (address);
    function isPool(address) external view returns (bool);
    function add(uint256 allocPoint, IERC20 token) external;
    function fund(uint256 amount, uint256 duration) external;
    function endTime() external view returns (uint256);
}

/// Adds every graduated launchpad token to the reward programs:
///   * its TOKEN/DOGE LP to KingFarm   (people who add liquidity earn KingS)
///   * the token itself to KingStake   (holders who stake it earn KingS)
/// Safe to run again: pools that are already listed are skipped.
///
/// Env (optional):
///   MEME_FARM_ALLOC   farm weight per meme LP      (default 10; KingS/DOGE LP has 40)
///                     (once KingVote runs the farm, new pools start at its base weight and votes decide)
///   MEME_STAKE_ALLOC  stake weight per meme token  (default 5;  KingS has 40)
///   FARM_TOPUP        extra KingS for the farm, whole tokens  (default 0)
///   STAKE_TOPUP       extra KingS for staking, whole tokens   (default 0)
/// A top-up is spread over the time left in the current period (30 days if it ended).
contract AddMemePools is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 fa = vm.envOr("MEME_FARM_ALLOC", uint256(10));
        uint256 sa = vm.envOr("MEME_STAKE_ALLOC", uint256(5));
        uint256 ftop = vm.envOr("FARM_TOPUP", uint256(0)) * 1e18;
        uint256 stop_ = vm.envOr("STAKE_TOPUP", uint256(0)) * 1e18;

        string memory json = AddrBook.read();
        ILaunchList lp = ILaunchList(AddrBook.get(json, "launch"));
        IRewards farm = IRewards(AddrBook.getOr(json, "farm", address(0)));
        IRewards stake = IRewards(AddrBook.getOr(json, "stake", address(0)));
        address kings = AddrBook.get(json, "kings");

        uint256 n = lp.count();
        uint256 added;
        vm.startBroadcast(pk);
        for (uint256 i; i < n; i++) {
            address t = lp.tokens(i);
            ILaunchList.Launch memory L = lp.info(t);
            if (!L.graduated) continue;
            if (address(farm) != address(0) && fa > 0 && !farm.isPool(L.pair)) {
                if (farm.owner() == vm.addr(pk)) farm.add(fa, IERC20(L.pair));
                else IVoteAdmin(farm.owner()).addFarmPool(IERC20(L.pair)); // farm run by KingVote: pool starts at the base weight
                console2.log("  farm  +", L.symbol, L.pair);
                added++;
            }
            if (address(stake) != address(0) && sa > 0 && !stake.isPool(t)) {
                stake.add(sa, IERC20(t));
                console2.log("  stake +", L.symbol, t);
                added++;
            }
        }
        if (ftop > 0 && address(farm) != address(0)) {
            if (farm.owner() == vm.addr(pk)) _topup(farm, kings, ftop);
            else _topupVote(IVoteAdmin(farm.owner()), farm, kings, ftop);
        }
        if (stop_ > 0 && address(stake) != address(0)) _topup(stake, kings, stop_);
        vm.stopBroadcast();
        console2.log("Launches checked", n);
        console2.log("Pools added     ", added);
    }

    function _topupVote(IVoteAdmin v, IRewards farm, address kings, uint256 amount) internal {
        uint256 end = farm.endTime();
        uint256 dur = end > block.timestamp + 1 days ? end - block.timestamp : 30 days;
        IERC20(kings).approve(address(v), amount);
        v.fundFarm(amount, dur);
        console2.log("  farm topped up via KingVote (KingS, days)", amount / 1e18, dur / 1 days);
    }

    function _topup(IRewards r, address kings, uint256 amount) internal {
        uint256 end = r.endTime();
        uint256 dur = end > block.timestamp + 1 days ? end - block.timestamp : 30 days;
        IERC20(kings).approve(address(r), amount);
        r.fund(amount, dur);
        console2.log("  topped up (KingS, days)", amount / 1e18, dur / 1 days);
    }
}
