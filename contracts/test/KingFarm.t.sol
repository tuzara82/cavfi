// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KingFarm} from "../src/KingFarm.sol";
import {KingS} from "../src/KingS.sol";

contract MockLP is ERC20 {
    constructor() ERC20("LP", "LP") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract KingFarmTest is Test {
    KingS kings;
    KingFarm farm;
    MockLP lpA;
    MockLP lpB;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 constant BUDGET = 30_000_000 ether;
    uint256 constant DAYS30 = 30 days;

    function setUp() public {
        kings = new KingS(address(this), 1_000_000_000 ether);
        farm = new KingFarm(IERC20(address(kings)), address(this));
        lpA = new MockLP(); lpB = new MockLP();
        farm.add(300, IERC20(address(lpA)));
        farm.add(100, IERC20(address(lpB)));
        kings.approve(address(farm), type(uint256).max);
        farm.fund(BUDGET, DAYS30);
        _user(alice);
        _user(bob);
    }

    function _user(address w) internal {
        lpA.mint(w, 1000 ether); lpB.mint(w, 1000 ether);
        vm.startPrank(w);
        lpA.approve(address(farm), type(uint256).max);
        lpB.approve(address(farm), type(uint256).max);
        vm.stopPrank();
    }

    function test_rate() public view {
        assertEq(farm.rewardPerSecond(), BUDGET / DAYS30);
        assertEq(farm.poolRewardPerSecond(0), farm.rewardPerSecond() * 3 / 4);
    }

    function test_singleStakerGetsPoolShare() public {
        vm.prank(alice); farm.deposit(0, 100 ether);
        skip(1 days);
        uint256 expected = 1 days * farm.rewardPerSecond() * 300 / 400;
        assertApproxEqAbs(farm.pendingReward(0, alice), expected, 1e6);
        vm.prank(alice); farm.harvest(0);
        assertApproxEqAbs(kings.balanceOf(alice), expected, 1e6);
        assertEq(farm.pendingReward(0, alice), 0);
    }

    function test_twoStakersSplitByStake() public {
        vm.prank(alice); farm.deposit(0, 300 ether);
        vm.prank(bob);   farm.deposit(0, 100 ether);
        skip(10 days);
        uint256 a = farm.pendingReward(0, alice);
        uint256 b = farm.pendingReward(0, bob);
        assertApproxEqRel(a, b * 3, 1e12);
    }

    function test_lateJoinerGetsOnlyLaterRewards() public {
        vm.prank(alice); farm.deposit(0, 100 ether);
        skip(1 days);
        vm.prank(bob); farm.deposit(0, 100 ether);
        skip(1 days);
        uint256 perDay = 1 days * farm.rewardPerSecond() * 3 / 4;
        assertApproxEqAbs(farm.pendingReward(0, alice), perDay + perDay / 2, 1e8);
        assertApproxEqAbs(farm.pendingReward(0, bob), perDay / 2, 1e8);
    }

    function test_stopsAtEndAndNeverOverpays() public {
        vm.prank(alice); farm.deposit(0, 100 ether);
        vm.prank(bob);   farm.deposit(1, 100 ether);
        skip(60 days);
        vm.prank(alice); farm.withdraw(0, 100 ether);
        vm.prank(bob);   farm.withdraw(1, 100 ether);
        uint256 paid = kings.balanceOf(alice) + kings.balanceOf(bob);
        assertLe(paid, BUDGET);
        assertApproxEqRel(paid, BUDGET, 1e9);
        assertEq(lpA.balanceOf(alice), 1000 ether);
        assertEq(farm.poolRewardPerSecond(0), 0);
    }

    function test_refundRollsOverLeftover() public {
        vm.prank(alice); farm.deposit(0, 100 ether);
        skip(15 days);
        farm.fund(BUDGET, DAYS30);
        // leftover half of the first budget + new budget, over 30 days
        assertApproxEqRel(farm.rewardPerSecond(), (BUDGET / 2 + BUDGET) / DAYS30, 1e12);
    }

    function test_emptyPoolRewardsAreRecoverable() public {
        vm.prank(alice); farm.deposit(0, 100 ether); // pool 1 stays empty
        skip(10 days);
        farm.massUpdatePools();
        uint256 lost = 10 days * farm.rewardPerSecond() * 100 / 400;
        assertApproxEqRel(farm.unallocated(), lost, 1e9);
        uint256 before = kings.balanceOf(address(this));
        farm.recoverUnallocated(address(this));
        assertApproxEqRel(kings.balanceOf(address(this)) - before, lost, 1e9);
        // alice still gets everything she earned
        skip(20 days);
        vm.prank(alice); farm.withdraw(0, 100 ether);
        assertApproxEqRel(kings.balanceOf(alice), BUDGET * 3 / 4, 1e9);
    }

    function test_emergencyWithdraw() public {
        vm.prank(alice); farm.deposit(0, 100 ether);
        skip(1 days);
        vm.prank(alice); farm.emergencyWithdraw(0);
        assertEq(lpA.balanceOf(alice), 1000 ether);
        assertEq(kings.balanceOf(alice), 0);
        assertEq(farm.pendingReward(0, alice), 0);
    }

    function test_onlyOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        farm.add(1, IERC20(address(0x1234)));
        vm.expectRevert();
        farm.fund(1, 1);
        vm.expectRevert();
        farm.recoverUnallocated(alice);
        vm.stopPrank();
    }

    function test_noDuplicateOrRewardTokenPool() public {
        vm.expectRevert(bytes("KingFarm: POOL_EXISTS"));
        farm.add(1, IERC20(address(lpA)));
        vm.expectRevert(bytes("KingFarm: REWARD_TOKEN"));
        farm.add(1, IERC20(address(kings)));
    }

    function test_cannotWithdrawMoreThanStaked() public {
        vm.prank(alice); farm.deposit(0, 10 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("KingFarm: AMOUNT"));
        farm.withdraw(0, 11 ether);
    }

    function testFuzz_solvent(uint32 t1, uint32 t2, uint96 a, uint96 b) public {
        _stake(alice, bound(a, 1, 1000 ether));
        skip(bound(t1, 0, 40 days));
        _stake(bob, bound(b, 1, 1000 ether));
        skip(bound(t2, 0, 40 days));
        _exit(alice);
        _exit(bob);
        uint256 paid = kings.balanceOf(alice) + kings.balanceOf(bob);
        assertLe(paid, BUDGET);
        assertEq(farm.totalPaid(), paid);
    }

    function _stake(address w, uint256 amt) internal { vm.prank(w); farm.deposit(0, amt); }
    function _exit(address w) internal {
        (uint256 amt,) = farm.userInfo(0, w);
        vm.prank(w); farm.withdraw(0, amt);
    }
}
