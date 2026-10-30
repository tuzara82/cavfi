// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KingEventBadges} from "../src/KingEventBadges.sol";

contract KingEventBadgesTest is Test {
    KingEventBadges e;
    address bot = address(0xB07);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        e = new KingEventBadges(address(this), bot);
        e.addBadge(1, "Spooktober 2026", "Halloween quests.", "<svg xmlns='http://www.w3.org/2000/svg'/>");
    }

    function test_awardOnceSoulbound() public {
        address[] memory to = new address[](2);
        to[0] = alice; to[1] = alice;
        vm.prank(bot); e.award(to, 1);
        assertEq(e.balanceOf(alice, 1), 1);
        assertEq(e.badge(1).holders, 1);
        vm.prank(alice);
        vm.expectRevert(bytes("Events: soulbound"));
        e.safeTransferFrom(alice, bob, 1, 1, "");
        vm.prank(bob);
        vm.expectRevert(bytes("Events: not minter"));
        e.award(to, 1);
        vm.prank(bot);
        vm.expectRevert(bytes("Events: no badge"));
        e.award(to, 2);
        vm.expectRevert(bytes("Events: id"));
        e.addBadge(1, "x", "y", "z");
        assertGt(bytes(e.uri(1)).length, 50);
    }
}
