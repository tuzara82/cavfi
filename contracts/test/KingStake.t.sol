// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KingStake} from "../src/KingStake.sol";
import {KingS} from "../src/KingS.sol";
import {WDOGE} from "../src/WDOGE.sol";
import {TestStable} from "../src/TestStable.sol";

contract KingStakeTest is Test {
    KingS kings;
    WDOGE wdoge;
    TestStable usdt;
    KingStake st;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 constant BUDGET = 10_000_000 ether;
    uint256 constant PID_KINGS = 0;
    uint256 constant PID_DOGE = 1;
    uint256 constant PID_USDT = 2;

    function setUp() public {
        kings = new KingS(address(this), 1_000_000_000 ether);
        wdoge = new WDOGE();
        usdt = new TestStable("Test Tether USD", "USDT", address(this), 1_000_000e6);
        st = new KingStake(IERC20(address(kings)), address(wdoge), address(this));
        st.add(40, IERC20(address(kings)));
        st.add(30, IERC20(address(wdoge)));
        st.add(30, IERC20(address(usdt)));
        kings.approve(address(st), type(uint256).max);
        st.fund(BUDGET, 10 days);
        _user(alice);
        _user(bob);
    }

    function _user(address w) internal {
        kings.transfer(w, 1_000_000 ether);
        usdt.transfer(w, 10_000e6);
        vm.deal(w, 100 ether);
        vm.startPrank(w);
        kings.approve(address(st), type(uint256).max);
        usdt.approve(address(st), type(uint256).max);
        vm.stopPrank();
    }

    function test_stakeKingsEarnsAndPrincipalSafe() public {
        vm.prank(alice); st.deposit(PID_KINGS, 500_000 ether);
        assertEq(st.stakedReward(), 500_000 ether);
        assertEq(st.rewardBalance(), BUDGET);
        skip(1 days);
        uint256 expected = 1 days * st.rewardPerSecond() * 40 / 100;
        assertApproxEqAbs(st.pendingReward(PID_KINGS, alice), expected, 1e8);
        vm.prank(alice); st.withdraw(PID_KINGS, 500_000 ether);
        assertApproxEqAbs(kings.balanceOf(alice), 1_000_000 ether + expected, 1e8);
        assertEq(st.stakedReward(), 0);
    }

    function test_principalNeverPaysRewards() public {
        // only the KingS pool is staked, run far past the end: rewards stop at the budget,
        // and both stakers still get their full principal back
        vm.prank(alice); st.deposit(PID_KINGS, 600_000 ether);
        vm.prank(bob);   st.deposit(PID_KINGS, 400_000 ether);
        skip(100 days);
        vm.prank(alice); st.withdraw(PID_KINGS, 600_000 ether);
        vm.prank(bob);   st.withdraw(PID_KINGS, 400_000 ether);
        uint256 rewards = kings.balanceOf(alice) + kings.balanceOf(bob) - 2_000_000 ether;
        assertLe(rewards, BUDGET);
        assertApproxEqRel(rewards, BUDGET * 40 / 100, 1e9);
        // owner can recover the unused 60% but cannot touch principal (none left here anyway)
        uint256 before = kings.balanceOf(address(this));
        st.recoverUnallocated(address(this));
        assertApproxEqRel(kings.balanceOf(address(this)) - before, BUDGET * 60 / 100, 1e9);
    }

    function test_recoverNeverTakesStakedKings() public {
        vm.prank(alice); st.deposit(PID_KINGS, 700_000 ether);
        skip(20 days);
        st.recoverUnallocated(address(this));
        vm.prank(alice); st.withdraw(PID_KINGS, 700_000 ether);
        assertGe(kings.balanceOf(alice), 1_000_000 ether);
    }

    function test_nativeDoge() public {
        uint256 b0 = alice.balance;
        vm.prank(alice); st.depositNative{value: 5 ether}(PID_DOGE);
        assertEq(alice.balance, b0 - 5 ether);
        (uint256 amt,) = st.userInfo(PID_DOGE, alice);
        assertEq(amt, 5 ether);
        assertEq(wdoge.balanceOf(address(st)), 5 ether);
        skip(1 days);
        vm.prank(alice); st.withdrawNative(PID_DOGE, 5 ether);
        assertEq(alice.balance, b0);
        assertGt(kings.balanceOf(alice), 1_000_000 ether);
    }

    function test_nativeOnlyOnDogePool() public {
        vm.prank(alice);
        vm.expectRevert(bytes("KingStake: NOT_NATIVE_POOL"));
        st.depositNative{value: 1 ether}(PID_USDT);
    }

    function test_usdtSixDecimals() public {
        vm.prank(alice); st.deposit(PID_USDT, 100e6);
        vm.prank(bob);   st.deposit(PID_USDT, 300e6);
        skip(2 days);
        assertApproxEqRel(st.pendingReward(PID_USDT, bob), st.pendingReward(PID_USDT, alice) * 3, 1e12);
        vm.prank(bob); st.withdraw(PID_USDT, 300e6);
        assertEq(usdt.balanceOf(bob), 10_000e6);
    }

    function test_emergencyKeepsAccounting() public {
        vm.prank(alice); st.deposit(PID_KINGS, 100_000 ether);
        skip(1 days);
        vm.prank(alice); st.emergencyWithdraw(PID_KINGS);
        assertEq(kings.balanceOf(alice), 1_000_000 ether);
        assertEq(st.stakedReward(), 0);
    }

    function test_onlyOwner() public {
        vm.startPrank(alice);
        vm.expectRevert(); st.add(1, IERC20(address(0x1234)));
        vm.expectRevert(); st.fund(1, 1);
        vm.expectRevert(); st.recoverUnallocated(alice);
        vm.stopPrank();
    }

    function testFuzz_solventWithKingsStaked(uint32 t1, uint32 t2, uint96 a, uint96 b) public {
        uint256 sa = bound(a, 1, 1_000_000 ether);
        uint256 sb = bound(b, 1, 1_000_000 ether);
        vm.prank(alice); st.deposit(PID_KINGS, sa);
        skip(bound(t1, 0, 15 days));
        vm.prank(bob); st.deposit(PID_KINGS, sb);
        skip(bound(t2, 0, 15 days));
        vm.prank(alice); st.withdraw(PID_KINGS, sa);
        vm.prank(bob); st.withdraw(PID_KINGS, sb);
        uint256 rewards = kings.balanceOf(alice) + kings.balanceOf(bob) - 2_000_000 ether;
        assertLe(rewards, BUDGET);
        assertEq(st.totalPaid(), rewards);
        assertEq(st.stakedReward(), 0);
    }
}
