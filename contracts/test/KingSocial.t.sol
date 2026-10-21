// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KingSocial} from "../src/KingSocial.sol";

contract KingSocialTest is Test {
    KingSocial so;
    address a = address(0xA); address b = address(0xB); address c = address(0xC); address bot = address(0xB07);

    function setUp() public { so = new KingSocial(address(this), bot); vm.warp(1000); }

    function test_referrals() public {
        vm.prank(b); so.register(a);
        vm.prank(c); so.register(a);
        assertEq(so.refCount(a), 2);
        assertEq(so.referrerOf(b), a);
        vm.prank(b); vm.expectRevert(bytes("Social: already linked")); so.register(c);
        vm.prank(a); vm.expectRevert(bytes("Social: loop")); so.register(b);
        vm.prank(a); vm.expectRevert(bytes("Social: bad referrer")); so.register(a);
        (address[] memory u, address[] memory r) = so.referrals(0, 10);
        assertEq(u.length, 2); assertEq(r[1], a);
    }

    function test_comments() public {
        vm.startPrank(a);
        so.comment(address(0x70), "much wow");
        vm.expectRevert(bytes("Social: slow down")); so.comment(address(0x70), "again");
        vm.warp(1100);
        so.comment(address(0x70), "again");
        vm.expectRevert(bytes("Social: 1-280 characters")); so.comment(address(0x70), "");
        vm.stopPrank();
        assertEq(so.commentCount(), 2);
    }

    function test_herald() public {
        address[] memory to = new address[](1); to[0] = a;
        vm.prank(b); vm.expectRevert(bytes("Social: not minter")); so.awardHerald(to);
        vm.prank(bot); so.awardHerald(to);
        vm.prank(bot); so.awardHerald(to);
        assertEq(so.balanceOf(a, 1), 1);
        vm.prank(a); vm.expectRevert(bytes("Social: soulbound")); so.safeTransferFrom(a, b, 1, 1, "");
        assertGt(bytes(so.uri(1)).length, 100);
    }
}
