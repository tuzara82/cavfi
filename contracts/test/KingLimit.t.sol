// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KingS} from "../src/KingS.sol";
import {WDOGE} from "../src/WDOGE.sol";
import {KingFactory} from "../src/KingFactory.sol";
import {KingRouter} from "../src/KingRouter.sol";
import {KingLimit} from "../src/KingLimit.sol";

contract KingLimitTest is Test {
    KingS kings;
    WDOGE wdoge;
    KingFactory factory;
    KingRouter router;
    KingLimit lim;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address keeper = address(0xBEEF);

    function setUp() public {
        wdoge = new WDOGE();
        factory = new KingFactory(address(this), address(0));
        router = new KingRouter(address(factory), address(wdoge));
        lim = new KingLimit(address(router), address(wdoge));
        kings = new KingS(alice, 1_000_000_000 ether);
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 100 ether);
        vm.startPrank(alice);
        kings.approve(address(router), type(uint256).max);
        router.addLiquidityETH{value: 100 ether}(address(kings), 1_000_000 ether, 0, 0, alice, block.timestamp); // 1 DOGE = 10,000 KingS
        vm.stopPrank();
    }

    function _p(address a, address b) internal pure returns (address[] memory p) { p = new address[](2); p[0] = a; p[1] = b; }

    function test_nativeBuyOrderFillsWhenPriceReached() public {
        // Bob wants 11,000 KingS per DOGE (better than the 10,000 market): not fillable yet
        vm.prank(bob);
        uint256 id = lim.placeNative{value: 1 ether}(address(kings), 11_000 ether, uint64(block.timestamp + 1 days));
        vm.prank(keeper);
        vm.expectRevert();
        lim.fill(id, _p(address(wdoge), address(kings)));
        // someone dumps KingS, DOGE gets dearer in KingS terms
        vm.startPrank(alice);
        router.swapExactTokensForETH(150_000 ether, 0, _p(address(kings), address(wdoge)), alice, block.timestamp);
        vm.stopPrank();
        vm.prank(keeper);
        uint256 out = lim.fill(id, _p(address(wdoge), address(kings)));
        assertGe(out, 11_000 ether);
        assertEq(kings.balanceOf(bob), out);
        assertEq(wdoge.balanceOf(keeper), 0.001 ether, "0.1% tip");
        assertEq(uint256(lim.get(id).status), uint256(KingLimit.Status.Filled));
    }

    function test_sellForNativeDoge() public {
        vm.prank(alice);
        kings.transfer(bob, 20_000 ether);
        vm.startPrank(bob);
        kings.approve(address(lim), 20_000 ether);
        uint256 id = lim.place(address(kings), address(wdoge), 20_000 ether, 1.5 ether, uint64(block.timestamp + 1 days), true);
        vm.stopPrank();
        uint256 b0 = bob.balance;
        lim.fill(id, _p(address(kings), address(wdoge)));
        assertGe(bob.balance - b0, 1.5 ether);
        assertEq(wdoge.balanceOf(bob), 0);
    }

    function test_cancelAndExpiry() public {
        vm.prank(bob);
        uint256 id = lim.placeNative{value: 2 ether}(address(kings), 1 ether, uint64(block.timestamp + 1 hours));
        vm.prank(keeper);
        vm.expectRevert(bytes("KingLimit: NOT_MAKER"));
        lim.cancel(id);
        uint256 b0 = bob.balance;
        vm.prank(bob);
        lim.cancel(id);
        assertEq(bob.balance - b0, 2 ether, "native refund");

        vm.prank(bob);
        uint256 id2 = lim.placeNative{value: 1 ether}(address(kings), 1 ether, uint64(block.timestamp + 1 hours));
        vm.warp(block.timestamp + 2 hours);
        vm.prank(keeper);
        vm.expectRevert(bytes("KingLimit: EXPIRED"));
        lim.fill(id2, _p(address(wdoge), address(kings)));
        vm.prank(keeper);
        lim.cancel(id2); // anyone can return an expired order
        assertEq(uint256(lim.get(id2).status), uint256(KingLimit.Status.Cancelled));
        vm.prank(bob);
        vm.expectRevert(bytes("KingLimit: NOT_OPEN"));
        lim.cancel(id2);
    }

    function test_badPathAndViews() public {
        vm.prank(bob);
        uint256 id = lim.placeNative{value: 1 ether}(address(kings), 1, uint64(block.timestamp + 1 days));
        vm.expectRevert(bytes("KingLimit: PATH"));
        lim.fill(id, _p(address(kings), address(wdoge)));
        assertEq(lim.count(), 1);
        assertEq(lim.idsOf(bob).length, 1);
        (uint256[] memory ids, KingLimit.Order[] memory items) = lim.range(0, 10);
        assertEq(ids.length, 1);
        assertEq(items[0].maker, bob);
        assertEq(address(lim).balance, 0);
        assertEq(wdoge.balanceOf(address(lim)), 1 ether);
    }

    function test_rejectsBadOrders() public {
        vm.startPrank(bob);
        vm.expectRevert(bytes("KingLimit: EXPIRY"));
        lim.placeNative{value: 1 ether}(address(kings), 1, uint64(block.timestamp));
        vm.expectRevert(bytes("KingLimit: SAME_TOKEN"));
        lim.placeNative{value: 1 ether}(address(wdoge), 1, uint64(block.timestamp + 1));
        vm.expectRevert(bytes("KingLimit: MIN_OUT"));
        lim.placeNative{value: 1 ether}(address(kings), 0, uint64(block.timestamp + 1));
        vm.stopPrank();
    }
}
