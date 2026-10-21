// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KingS} from "../src/KingS.sol";
import {WDOGE} from "../src/WDOGE.sol";
import {KingFactory} from "../src/KingFactory.sol";
import {KingRouter} from "../src/KingRouter.sol";
import {KingPair} from "../src/KingPair.sol";

contract KingSwapTest is Test {
    KingS kings;
    WDOGE wdoge;
    KingFactory factory;
    KingRouter router;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        wdoge = new WDOGE();
        factory = new KingFactory(address(this), address(0));
        router = new KingRouter(address(factory), address(wdoge));
        kings = new KingS(alice, 1_000_000_000 ether);
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 100 ether);

        vm.startPrank(alice);
        kings.approve(address(router), type(uint256).max);
        router.addLiquidityETH{value: 100 ether}(address(kings), 1_000_000 ether, 0, 0, alice, block.timestamp);
        vm.stopPrank();
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function test_supply() public view {
        assertEq(kings.totalSupply(), 1_000_000_000 ether);
        assertEq(kings.symbol(), "KingS");
    }

    function test_poolCreated() public view {
        address pair = factory.getPair(address(kings), address(wdoge));
        assertTrue(pair != address(0));
        (uint256 rK, uint256 rD) = router.getReserves(address(kings), address(wdoge));
        assertEq(rK, 1_000_000 ether);
        assertEq(rD, 100 ether);
        assertGt(KingPair(pair).balanceOf(alice), 0);
    }

    function test_swapDogeForKingS() public {
        uint256[] memory q = router.getAmountsOut(1 ether, _path(address(wdoge), address(kings)));
        vm.prank(bob);
        router.swapExactETHForTokens{value: 1 ether}(q[1], _path(address(wdoge), address(kings)), bob, block.timestamp);
        assertEq(kings.balanceOf(bob), q[1]);
        // ~9871 KingS for 1 DOGE at 10,000 KingS/DOGE minus 0.3% fee and price impact
        assertApproxEqRel(q[1], 9871.580343970 ether, 1e14);
    }

    function test_swapKingSForDoge() public {
        vm.prank(alice);
        kings.transfer(bob, 50_000 ether);
        uint256 before = bob.balance;
        vm.startPrank(bob);
        kings.approve(address(router), type(uint256).max);
        uint256[] memory q = router.getAmountsOut(10_000 ether, _path(address(kings), address(wdoge)));
        router.swapExactTokensForETH(10_000 ether, q[1], _path(address(kings), address(wdoge)), bob, block.timestamp);
        vm.stopPrank();
        assertEq(bob.balance - before, q[1]);
    }

    function test_slippageReverts() public {
        uint256[] memory q = router.getAmountsOut(1 ether, _path(address(wdoge), address(kings)));
        vm.prank(bob);
        vm.expectRevert(bytes("KingRouter: INSUFFICIENT_OUTPUT_AMOUNT"));
        router.swapExactETHForTokens{value: 1 ether}(q[1] + 1, _path(address(wdoge), address(kings)), bob, block.timestamp);
    }

    function test_removeLiquidity() public {
        address pair = factory.getPair(address(kings), address(wdoge));
        uint256 lp = KingPair(pair).balanceOf(alice);
        vm.startPrank(alice);
        KingPair(pair).approve(address(router), lp);
        uint256 dogeBefore = alice.balance;
        router.removeLiquidityETH(address(kings), lp, 0, 0, alice, block.timestamp);
        vm.stopPrank();
        assertApproxEqAbs(alice.balance - dogeBefore, 100 ether, 1e12);
    }

    function testFuzz_kHolds(uint96 amt) public {
        vm.assume(amt > 1e9 && amt < 50 ether);
        address pair = factory.getPair(address(kings), address(wdoge));
        (uint112 r0, uint112 r1,) = KingPair(pair).getReserves();
        uint256 kBefore = uint256(r0) * r1;
        vm.deal(bob, amt);
        vm.prank(bob);
        router.swapExactETHForTokens{value: amt}(0, _path(address(wdoge), address(kings)), bob, block.timestamp);
        (r0, r1,) = KingPair(pair).getReserves();
        assertGe(uint256(r0) * r1, kBefore);
    }
}

import {TestStable} from "../src/TestStable.sol";

contract StableTest is Test {
    TestStable usdt;
    address u = address(0xC0FFEE);

    function setUp() public {
        usdt = new TestStable("Test Tether USD", "USDT", address(this), 1_000e6);
    }

    function test_decimals() public view {
        assertEq(usdt.decimals(), 6);
    }

    function test_faucetCooldown() public {
        vm.warp(10 days);
        vm.prank(u);
        usdt.faucet();
        assertEq(usdt.balanceOf(u), 1_000e6);
        vm.prank(u);
        vm.expectRevert(bytes("TestStable: wait 1 hour between claims"));
        usdt.faucet();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(u);
        usdt.faucet();
        assertEq(usdt.balanceOf(u), 2_000e6);
    }
}

contract FeeTest is Test {
    KingS kings;
    WDOGE wdoge;
    KingFactory factory;
    KingRouter router;
    address treasury = address(0x7EA5);
    address lp = address(0x1111);
    address trader = address(0x2222);

    function setUp() public {
        wdoge = new WDOGE();
        factory = new KingFactory(address(this), treasury);
        router = new KingRouter(address(factory), address(wdoge));
        kings = new KingS(lp, 1_000_000_000 ether);
        vm.deal(lp, 1_000 ether);
        vm.deal(trader, 10_000 ether);
        vm.startPrank(lp);
        kings.approve(address(router), type(uint256).max);
        router.addLiquidityETH{value: 100 ether}(address(kings), 1_000_000 ether, 0, 0, lp, block.timestamp);
        vm.stopPrank();
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2); p[0] = a; p[1] = b;
    }

    function _trade(uint256 rounds) internal {
        vm.startPrank(trader);
        kings.approve(address(router), type(uint256).max);
        for (uint256 i; i < rounds; i++) {
            uint256[] memory out = router.swapExactETHForTokens{value: 10 ether}(0, _path(address(wdoge), address(kings)), trader, block.timestamp);
            router.swapExactTokensForETH(out[1], 0, _path(address(kings), address(wdoge)), trader, block.timestamp);
        }
        vm.stopPrank();
    }

    function test_feeSplitIsOneSixth() public {
        KingPair pair = KingPair(factory.getPair(address(kings), address(wdoge)));
        (uint112 a, uint112 b,) = pair.getReserves();
        uint256 rootK0 = Math_sqrt(uint256(a) * b);
        _trade(20);
        (a, b,) = pair.getReserves();
        uint256 rootK1 = Math_sqrt(uint256(a) * b);
        uint256 supply = pair.totalSupply();
        assertGt(rootK1, rootK0, "fees grew the pool");
        assertEq(pair.balanceOf(treasury), 0, "minted lazily");

        vm.prank(lp);
        router.addLiquidityETH{value: 1 ether}(address(kings), 1_000_000 ether, 0, 0, lp, block.timestamp);
        uint256 t = pair.balanceOf(treasury);

        // exact Uniswap V2 formula
        assertEq(t, supply * (rootK1 - rootK0) / (rootK1 * 5 + rootK0));
        // economic meaning: treasury owns 1/6 of the value the fees added
        uint256 treasuryShareOfPool = t * 1e18 / (supply + t);
        uint256 feeGrowthShare = (rootK1 - rootK0) * 1e18 / rootK1;
        assertApproxEqRel(treasuryShareOfPool, feeGrowthShare / 6, 0.001e18);
    }

    function Math_sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) { z = y; uint256 x = y / 2 + 1; while (x < z) { z = x; x = (y / x + x) / 2; } } else if (y != 0) z = 1;
    }

    function test_feeOffMintsNothing() public {
        factory.setFeeTo(address(0));
        KingPair pair = KingPair(factory.getPair(address(kings), address(wdoge)));
        _trade(5);
        vm.prank(lp);
        router.addLiquidityETH{value: 1 ether}(address(kings), 1_000_000 ether, 0, 0, lp, block.timestamp);
        assertEq(pair.balanceOf(treasury), 0);
        assertEq(pair.kLast(), 0);
    }

    function test_onlySetterCanChangeFee() public {
        vm.prank(trader);
        vm.expectRevert(bytes("KingFactory: FORBIDDEN"));
        factory.setFeeTo(trader);
        factory.setFeeToSetter(lp);
        vm.expectRevert(bytes("KingFactory: FORBIDDEN"));
        factory.setFeeTo(trader);
        vm.prank(lp);
        factory.setFeeTo(trader);
        assertEq(factory.feeTo(), trader);
    }

    function test_treasuryCanWithdraw() public {
        KingPair pair = KingPair(factory.getPair(address(kings), address(wdoge)));
        _trade(20);
        vm.prank(lp);
        router.addLiquidityETH{value: 1 ether}(address(kings), 1_000_000 ether, 0, 0, lp, block.timestamp);
        uint256 t = pair.balanceOf(treasury);
        vm.startPrank(treasury);
        pair.approve(address(router), t);
        (uint256 k, uint256 d) = router.removeLiquidityETH(address(kings), t, 0, 0, treasury, block.timestamp);
        vm.stopPrank();
        assertGt(k, 0); assertGt(d, 0);
        assertEq(treasury.balance, d);
    }
}
