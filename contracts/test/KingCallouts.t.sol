// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WDOGE} from "../src/WDOGE.sol";
import {KingFactory} from "../src/KingFactory.sol";
import {KingPair} from "../src/KingPair.sol";
import {KingLaunch} from "../src/KingLaunch.sol";
import {KingCallouts} from "../src/KingCallouts.sol";

contract KingCalloutsTest is Test {
    WDOGE wdoge;
    KingFactory factory;
    KingLaunch lp;
    KingCallouts co;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.warp(1_800_000_000);
        wdoge = new WDOGE();
        factory = new KingFactory(address(this), address(0));
        lp = new KingLaunch(address(factory), address(wdoge), keccak256(type(KingPair).creationCode), address(this), address(0xFEE), 5 ether, 0);
        co = new KingCallouts(lp);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _launch(string memory s) internal returns (address t) {
        vm.prank(alice);
        t = lp.create(s, s, "", "", 0);
    }

    function test_callRecordsCurvePriceAndMultipleGrows() public {
        address t = _launch("A");
        vm.prank(bob);
        uint256 id = co.call(t);
        KingCallouts.Call memory c = co.get(id);
        assertEq(c.caller, bob);
        KingLaunch.Launch memory L = lp.info(t);
        assertEq(c.price, L.vDoge * 1e18 / L.vTok);
        vm.prank(alice); lp.buy{value: 2 ether}(t, 0);
        (, KingCallouts.Call[] memory items, uint256[] memory nowP) = co.page(0, 10);
        assertEq(items.length, 1);
        assertGt(nowP[0], c.price);   // price went up after the buy
        assertEq(co.idsOfToken(t).length, 1);
        assertEq(co.idsOfCaller(bob)[0], id);
    }

    function test_oncePerTokenAndThreeADay() public {
        address[4] memory ts = [_launch("A"), _launch("B"), _launch("C"), _launch("D")];
        vm.startPrank(bob);
        co.call(ts[0]);
        vm.expectRevert(bytes("Callouts: already called"));
        co.call(ts[0]);
        co.call(ts[1]);
        co.call(ts[2]);
        assertEq(co.callsLeftToday(bob), 0);
        vm.expectRevert(bytes("Callouts: 3 calls a day"));
        co.call(ts[3]);
        vm.warp(block.timestamp + 1 days);
        co.call(ts[3]);
        vm.expectRevert(bytes("Callouts: not a CavFi launch"));
        co.call(address(0xDEAD));
        vm.stopPrank();
        assertEq(co.count(), 4);
    }

    function test_graduatedUsesPoolPrice() public {
        address t = _launch("G");
        vm.prank(bob); lp.buy{value: 20 ether}(t, 0);   // fills the 5 DOGE curve: graduates
        KingLaunch.Launch memory L = lp.info(t);
        assertTrue(L.graduated);
        uint256 p = co.priceOf(t);
        assertGt(p, 0);
        (uint112 r0, uint112 r1,) = KingPair(L.pair).getReserves();
        (uint256 rT, uint256 rD) = KingPair(L.pair).token0() == t ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        assertEq(p, rD * 1e18 / rT);
    }
}
