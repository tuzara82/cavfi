// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KingNames} from "../src/KingNames.sol";
import {KingGM} from "../src/KingGM.sol";

contract KingNamesTest is Test {
    KingNames names;
    address owner = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    receive() external payable {}

    function setUp() public {
        names = new KingNames(owner, 10 ether, 5 ether, 1 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function test_register_prices_and_primary() public {
        vm.prank(alice);
        names.register{value: 1 ether}("borislav");
        assertEq(names.resolve("borislav"), alice);
        assertEq(names.nameOf(alice), "borislav");
        vm.prank(alice);
        names.register{value: 10 ether}("dog");
        assertEq(names.nameOf(alice), "borislav"); // first one stays primary
        uint256 dogId = names.idOf("dog");
        vm.prank(alice);
        names.setPrimary(dogId);
        assertEq(names.nameOf(alice), "dog");
        vm.prank(bob);
        names.register{value: 5 ether}("doge");
        assertEq(names.totalNames(), 3);
        assertEq(address(names).balance, 16 ether);
        names.withdraw();
        assertEq(address(names).balance, 0);
    }

    function test_rules() public {
        vm.startPrank(alice);
        vm.expectRevert(KingNames.BadName.selector);
        names.register{value: 1 ether}("ab");
        vm.expectRevert(KingNames.BadName.selector);
        names.register{value: 1 ether}("Boris");
        vm.expectRevert(KingNames.BadName.selector);
        names.register{value: 1 ether}("-boris");
        vm.expectRevert(KingNames.BadName.selector);
        names.register{value: 1 ether}("bo ris");
        vm.expectRevert(KingNames.BadName.selector);
        names.register{value: 1 ether}("<svg>");
        vm.expectRevert(KingNames.WrongPayment.selector);
        names.register{value: 1 ether}("cat");
        names.register{value: 1 ether}("my-name-1");
        vm.expectRevert(KingNames.Taken.selector);
        names.register{value: 1 ether}("my-name-1");
        vm.stopPrank();
        uint256 mid = names.idOf("my-name-1");
        vm.prank(bob);
        vm.expectRevert(KingNames.NotOwner.selector);
        names.setPrimary(mid);
        assertFalse(names.available("my-name-1"));
        assertTrue(names.available("free-one"));
    }

    function test_transfer_moves_ownership_and_clears_primary() public {
        vm.prank(alice);
        uint256 id = names.register{value: 1 ether}("cavalier");
        vm.prank(alice);
        names.transferFrom(alice, bob, id);
        assertEq(names.resolve("cavalier"), bob);
        assertEq(names.nameOf(alice), "");
        assertEq(names.nameOf(bob), ""); // bob must choose it
        vm.prank(bob);
        names.setPrimary(id);
        assertEq(names.nameOf(bob), "cavalier");
        address[] memory w = new address[](2);
        (w[0], w[1]) = (alice, bob);
        string[] memory out = names.namesOf(w);
        assertEq(out[1], "cavalier");
        assertGt(bytes(names.tokenURI(id)).length, 200);
    }

    function test_owner_prices() public {
        vm.prank(alice);
        vm.expectRevert();
        names.setPrices(0, 0, 0);
        names.setPrices(3 ether, 2 ether, 0);
        vm.prank(alice);
        names.register{value: 0}("freebie");
        assertEq(names.priceOf("abc"), 3 ether);
    }
}

contract KingGMTest is Test {
    KingGM g;
    address alice = address(0xA11CE);

    function setUp() public {
        g = new KingGM();
        vm.warp(20_000 days + 3 hours);
    }

    function test_gm_gn_once_per_day() public {
        vm.startPrank(alice);
        g.gm();
        g.gn();
        vm.expectRevert(KingGM.AlreadyToday.selector);
        g.gm();
        vm.expectRevert(KingGM.AlreadyToday.selector);
        g.gn();
        vm.stopPrank();
        (bool gmT, bool gnT, uint256 streak,,,,,) = g.info(alice);
        assertTrue(gmT && gnT);
        assertEq(streak, 1);
    }

    function test_streak_badge_and_break() public {
        uint256 t = 20_000 days + 3 hours;
        for (uint256 i; i < 7; i++) {
            vm.prank(alice);
            g.gm();
            t += 1 days;
            vm.warp(t);
        }
        assertEq(g.balanceOf(alice, 1), 1);
        assertEq(g.streakOf(alice), 7); // last gm was yesterday, still alive
        t += 1 days;
        vm.warp(t); // skipped a day
        assertEq(g.streakOf(alice), 0);
        vm.prank(alice);
        g.gm();
        (,, uint256 streak, uint256 best,,, bool pup,) = g.info(alice);
        assertEq(streak, 1);
        assertEq(best, 7);
        assertTrue(pup);
        vm.prank(alice);
        vm.expectRevert(bytes("GM: soulbound"));
        g.safeTransferFrom(alice, address(1), 1, 1, "");
    }
}

contract KingNamesListTest is Test {
    KingNames names;
    address alice = address(0xA11CE);

    function setUp() public {
        names = new KingNames(address(this), 10 ether, 5 ether, 1 ether);
        vm.deal(alice, 100 ether);
    }

    function test_lists() public {
        vm.startPrank(alice);
        names.register{value: 1 ether}("first");
        names.register{value: 1 ether}("second");
        vm.stopPrank();
        (string[] memory l,) = names.labelsOf(alice);
        assertEq(l.length, 2);
        assertEq(l[1], "second");
        (string[] memory r, address[] memory o) = names.recent(5);
        assertEq(r.length, 2);
        assertEq(r[0], "second");
        assertEq(o[0], alice);
    }
}
