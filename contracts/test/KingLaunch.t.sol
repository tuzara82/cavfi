// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WDOGE} from "../src/WDOGE.sol";
import {KingFactory} from "../src/KingFactory.sol";
import {KingRouter} from "../src/KingRouter.sol";
import {KingPair} from "../src/KingPair.sol";
import {KingLaunch} from "../src/KingLaunch.sol";
import {MemeToken} from "../src/MemeToken.sol";

contract KingLaunchTest is Test {
    WDOGE wdoge;
    KingFactory factory;
    KingRouter router;
    KingLaunch lp;
    address fee = address(0xFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address eve = address(0xE5E);

    function setUp() public {
        wdoge = new WDOGE();
        factory = new KingFactory(address(this), address(0));
        router = new KingRouter(address(factory), address(wdoge));
        lp = new KingLaunch(address(factory), address(wdoge), keccak256(type(KingPair).creationCode), address(this), fee, 5 ether, 0);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(eve, 100 ether);
    }

    function _launch() internal returns (MemeToken t) {
        vm.prank(alice);
        t = MemeToken(lp.create("Royal Pup", "RPUP", "woof", "https://example.com/p.png", 0));
    }

    function test_createAndPredictedPair() public {
        MemeToken t = _launch();
        assertEq(t.totalSupply(), 1_000_000_000 ether);
        assertEq(t.balanceOf(address(lp)), 1_000_000_000 ether);
        assertEq(lp.count(), 1);
        assertEq(factory.getPair(address(t), address(wdoge)), address(0)); // not created yet
        address made = factory.createPair(address(t), address(wdoge));    // anyone may create it early
        assertEq(made, t.pair(), "predicted pair address must match the factory");
        KingLaunch.Launch memory L = lp.info(address(t));
        assertEq(L.creator, alice);
        assertEq(L.symbol, "RPUP");
    }

    function test_createWithFirstBuy() public {
        vm.prank(alice);
        address t = lp.create{value: 1 ether}("A", "A", "", "", 0);
        assertGt(MemeToken(t).balanceOf(alice), 0);
        assertEq(fee.balance, 0.01 ether);
    }

    function test_buySellRoundTripLosesOnlyFees() public {
        MemeToken t = _launch();
        uint256 b0 = bob.balance;
        vm.startPrank(bob);
        uint256 out = lp.buy{value: 1 ether}(address(t), 0);
        t.approve(address(lp), out);
        lp.sell(address(t), out, 0);
        vm.stopPrank();
        uint256 lost = b0 - bob.balance;
        assertApproxEqRel(lost, 0.0199 ether, 0.01e18); // ~1% in + ~1% out
        assertEq(address(lp).balance, lp.info(address(t)).realDoge);
    }

    function test_cannotSendToPairBeforeGraduation() public {
        MemeToken t = _launch();
        vm.startPrank(eve);
        lp.buy{value: 1 ether}(address(t), 0);
        address pair = t.pair();
        vm.expectRevert(bytes("MemeToken: pool opens after graduation"));
        t.transfer(pair, 1 ether);
        // plain transfers between people are fine
        t.transfer(bob, 1 ether);
        vm.stopPrank();
        assertEq(t.balanceOf(bob), 1 ether);
    }

    function test_graduationAtTargetWithRefundAndLockedLiquidity() public {
        MemeToken t = _launch();
        // a griefer donates WDOGE to the future pool and syncs it
        address pair = factory.createPair(address(t), address(wdoge));
        vm.startPrank(eve);
        wdoge.deposit{value: 0.5 ether}();
        wdoge.transfer(pair, 0.5 ether);
        KingPair(pair).sync();
        vm.stopPrank();

        uint256 b0 = bob.balance;
        vm.prank(bob);
        uint256 out = lp.buy{value: 20 ether}(address(t), 0);
        assertEq(out, 800_000_000 ether, "whole curve");
        uint256 spent = b0 - bob.balance;
        assertApproxEqRel(spent, uint256(5 ether) * 100 / 99, uint256(0.001e18), "exactly the target + fee, rest refunded");

        KingLaunch.Launch memory L = lp.info(address(t));
        assertTrue(L.graduated);
        assertTrue(t.graduated());
        assertEq(address(lp).balance, 0);
        assertEq(t.balanceOf(address(lp)), 0);
        (uint112 r0, uint112 r1, ) = KingPair(pair).getReserves();
        (uint256 rt, uint256 rd) = KingPair(pair).token0() == address(t) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        assertEq(rt, 200_000_000 ether);
        assertApproxEqAbs(rd, 5.5 ether, 0.001 ether); // target + the griefer's gift
        assertEq(KingPair(pair).balanceOf(alice), 0);
        assertGt(KingPair(pair).balanceOf(lp.DEAD()), 0, "LP burned");

        // curve is closed, trading continues on CavFi
        vm.expectRevert(bytes("KingLaunch: GRADUATED"));
        vm.prank(bob);
        lp.buy{value: 1 ether}(address(t), 0);
        address[] memory path = new address[](2);
        path[0] = address(wdoge);
        path[1] = address(t);
        vm.prank(eve);
        router.swapExactETHForTokens{value: 0.1 ether}(0, path, eve, block.timestamp);
        assertGt(t.balanceOf(eve), 0);
    }

    function test_curveEndPriceMatchesPool() public {
        MemeToken t = _launch();
        vm.prank(bob);
        lp.buy{value: 4.9 ether}(address(t), 0);
        KingLaunch.Launch memory L = lp.info(address(t));
        // marginal curve price before the last buy vs the pool price after graduation (5 DOGE : 200M)
        uint256 curvePx = L.vDoge * 1e18 / L.vTok;
        assertApproxEqRel(curvePx, uint256(5 ether) * 1e18 / 200_000_000 ether, 0.05e18);
    }

    function test_solvencyManyTrades() public {
        MemeToken t = _launch();
        for (uint256 i; i < 20; i++) {
            address u = i % 2 == 0 ? bob : eve;
            vm.startPrank(u);
            uint256 o = lp.buy{value: 0.13 ether + i * 0.01 ether}(address(t), 0);
            if (i % 3 == 0) {
                t.approve(address(lp), o / 2);
                lp.sell(address(t), o / 2, 0);
            }
            vm.stopPrank();
        }
        KingLaunch.Launch memory L = lp.info(address(t));
        assertEq(address(lp).balance, L.realDoge);
        assertEq(t.balanceOf(address(lp)), L.tokensLeft + lp.LP_TOKENS());
        assertEq(L.vTok - L.tokensLeft, lp.CURVE() * 4 / 3 - lp.CURVE());
    }

    function test_slippageAndAdmin() public {
        MemeToken t = _launch();
        (uint256 q, , , ) = lp.quoteBuy(address(t), 1 ether);
        vm.prank(bob);
        vm.expectRevert(bytes("KingLaunch: SLIPPAGE"));
        lp.buy{value: 1 ether}(address(t), q + 1);
        vm.prank(bob);
        vm.expectRevert();
        lp.setParams(bob, 1 ether, 0);
        lp.setParams(fee, 10 ether, 0.1 ether);
        vm.prank(bob);
        vm.expectRevert(bytes("KingLaunch: CREATE_FEE"));
        lp.create("B", "B", "", "", 0);
        vm.prank(bob);
        address t2 = lp.create{value: 0.1 ether}("B", "B", "", "", 0);
        assertEq(lp.info(t2).target, 10 ether);
        assertEq(lp.info(address(t)).target, 5 ether);
    }

    function test_noHashModeCreatesPairUpFront() public {
        KingLaunch lp2 = new KingLaunch(address(factory), address(wdoge), bytes32(0), address(this), fee, 1 ether, 0);
        vm.prank(alice);
        MemeToken t = MemeToken(lp2.create("C", "C", "", "", 0));
        assertEq(factory.getPair(address(t), address(wdoge)), t.pair());
        vm.prank(bob);
        lp2.buy{value: 3 ether}(address(t), 0);
        assertTrue(t.graduated());
    }
}
