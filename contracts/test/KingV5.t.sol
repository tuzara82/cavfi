// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KingGuess} from "../src/KingGuess.sol";
import {KingS} from "../src/KingS.sol";

contract KingGuessTest is Test {
    KingS kings;
    KingGuess g;
    address bot = address(0xB07);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);
    uint32 d;

    function setUp() public {
        vm.warp(1_790_000_000 / 1 days * 1 days + 10 hours); // 10:00 UTC
        kings = new KingS(address(this), 1_000_000 ether);
        g = new KingGuess(address(this), kings, bot, 10_000 ether);
        kings.transfer(address(g), 25_000 ether);
        d = g.today();
    }

    function test_closestWinsAndTieGoesToFirst() public {
        vm.prank(alice); g.guess(7_700_000);
        vm.prank(bob); g.guess(7_800_000);
        vm.prank(carol); g.guess(7_800_000);   // same as bob, later
        vm.prank(alice);
        vm.expectRevert(bytes("Guess: already guessed today"));
        g.guess(7_750_000);
        vm.prank(bot);
        vm.expectRevert(bytes("Guess: too early"));
        g.settle(d, 7_790_000);
        vm.warp(uint256(g.targetAt(d)) + 60);
        vm.prank(alice);
        vm.expectRevert(bytes("Guess: not oracle"));
        g.settle(d, 7_790_000);
        vm.prank(bot);
        g.settle(d, 7_790_000);
        assertEq(kings.balanceOf(bob), 10_000 ether);
        assertEq(kings.balanceOf(carol), 0);
        KingGuess.Day memory D = g.dayInfo(d);
        assertEq(D.winner, bob);
        assertEq(D.winnerGuess, 7_800_000);
        vm.prank(bot);
        vm.expectRevert(bytes("Guess: settled"));
        g.settle(d, 7_790_000);
    }

    function test_closedAfter18AndNextDayOpens() public {
        vm.warp(uint256(g.closeAt(d)));
        vm.prank(alice);
        vm.expectRevert(bytes("Guess: closed for today"));
        g.guess(7_700_000);
        vm.warp(uint256(d + 1) * 1 days + 1);
        vm.prank(alice); g.guess(7_700_000);
        assertEq(g.count(d + 1), 1);
        (uint64 p,) = g.guessOf(d + 1, alice);
        assertEq(p, 7_700_000);
    }

    function test_noPlayersKeepsPrizeAndFundRunsDry() public {
        vm.warp(uint256(g.targetAt(d)) + 1);
        vm.prank(bot); g.settle(d, 7_000_000);
        assertEq(kings.balanceOf(address(g)), 25_000 ether);
        // two days with players, the third pays whatever is left
        for (uint32 i = 1; i <= 3; i++) {
            vm.warp(uint256(d + i) * 1 days + 1 hours);
            vm.prank(alice); g.guess(7_000_000);
            vm.warp(uint256(g.targetAt(d + i)) + 1);
            vm.prank(bot); g.settle(d + i, 7_100_000);
        }
        assertEq(kings.balanceOf(alice), 25_000 ether);
        assertEq(g.dayInfo(d + 3).prize, 5_000 ether);
        KingGuess.Guess[] memory all = g.guesses(d + 1, 0, 10);
        assertEq(all.length, 1);
        assertEq(all[0].who, alice);
    }
}
