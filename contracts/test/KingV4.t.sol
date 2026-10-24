// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KingArenaTest, ArenaTestToken} from "./KingArena.t.sol";
import {KingDuel} from "../src/KingDuel.sol";
import {KingPredict} from "../src/KingPredict.sol";
import {KingS} from "../src/KingS.sol";

/// Duels reuse the Arena test setup to play real rounds.
contract KingDuelTest is KingArenaTest {
    KingDuel duel;

    function _deployDuel() internal {
        if (address(duel) != address(0)) return;
        duel = new KingDuel(address(arena), kings);
        address[3] memory us = [alice, bob, carol];
        for (uint256 i; i < us.length; ++i) { vm.prank(us[i]); kings.approve(address(duel), type(uint256).max); }
    }

    function test_duelWinnerTakesBoth() public {
        _deployDuel();
        uint256 id = _openRound();
        _step(60);
        vm.prank(alice);
        uint256 d = duel.create(0, 1, 1_000 ether, address(0)); // alice: AAA beats BBB
        vm.prank(alice);
        vm.expectRevert(bytes("Duel: yourself"));
        duel.accept(d);
        vm.prank(bob);
        duel.accept(d);
        assertEq(uint256(duel.get(d).state), uint256(KingDuel.State.Matched));
        _pokeN(3, 60);
        _step(20 minutes);
        _buy(0, 5_000 ether); // AAA rises
        _endWindow(id, 4);
        vm.expectRevert(bytes("Duel: round not settled"));
        duel.settle(d);
        _settleAt(id);
        uint256 before = kings.balanceOf(alice);
        vm.prank(carol);
        duel.settle(d); // anyone can settle
        assertEq(kings.balanceOf(alice) - before, 2_000 ether);
        assertEq(duel.get(d).winner, alice);
        assertEq(kings.balanceOf(address(duel)), 0);
    }

    function test_takerWinsWhenTheirTokenRises() public {
        _deployDuel();
        uint256 id = _openRound();
        _step(60);
        vm.prank(alice);
        uint256 d = duel.create(0, 1, 500 ether, address(0));
        vm.prank(bob);
        duel.accept(d);
        _pokeN(3, 60);
        _step(20 minutes);
        _buy(1, 5_000 ether); // BBB rises
        _endWindow(id, 4);
        _settleAt(id);
        uint256 before = kings.balanceOf(bob);
        duel.settle(d);
        assertEq(kings.balanceOf(bob) - before, 1_000 ether);
    }

    function test_tieRefundsBoth() public {
        _deployDuel();
        uint256 id = _openRound();
        _step(60);
        vm.prank(alice);
        uint256 d = duel.create(0, 1, 500 ether, address(0));
        vm.prank(bob);
        duel.accept(d);
        _pokeN(3, 60);
        _endWindow(id, 4); // nobody trades: both flat
        _settleAt(id);
        uint256 a0 = kings.balanceOf(alice);
        uint256 b0 = kings.balanceOf(bob);
        duel.settle(d);
        assertEq(kings.balanceOf(alice) - a0, 500 ether);
        assertEq(kings.balanceOf(bob) - b0, 500 ether);
        assertEq(duel.get(d).winner, address(0));
    }

    function test_inviteCancelAndClosedStaking() public {
        _deployDuel();
        uint256 id = _openRound();
        _step(60);
        vm.prank(alice);
        uint256 d = duel.create(0, 2, 100 ether, bob);
        vm.prank(carol);
        vm.expectRevert(bytes("Duel: not invited"));
        duel.accept(d);
        vm.prank(carol);
        vm.expectRevert(bytes("Duel: still open"));
        duel.cancel(d);
        // once staking closes nobody can accept, and anyone can send the stake back
        _endWindow(id, 1);
        vm.prank(bob);
        vm.expectRevert(bytes("Duel: staking closed"));
        duel.accept(d);
        uint256 a0 = kings.balanceOf(alice);
        vm.prank(carol);
        duel.cancel(d);
        assertEq(kings.balanceOf(alice) - a0, 100 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("Duel: staking closed"));
        duel.create(0, 1, 100 ether, address(0));
        vm.prank(alice);
        vm.expectRevert(); // same token twice / out of range
        duel.create(1, 1, 100 ether, address(0));
    }
}

contract KingPredictTest is Test {
    KingS kings;
    KingPredict pr;
    address bot = address(0xB07);
    address owner = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);

    function setUp() public {
        vm.warp(1_750_000_000);
        kings = new KingS(address(this), 1_000_000 ether);
        pr = new KingPredict(owner, kings, bot);
        pr.setFeeTo(address(0xFEE));
        address[3] memory us = [alice, bob, carol];
        for (uint256 i; i < 3; i++) { kings.transfer(us[i], 10_000 ether); vm.prank(us[i]); kings.approve(address(pr), type(uint256).max); }
    }

    function _market() internal returns (uint256) {
        vm.prank(bot);
        return pr.create("Will DOGE be above $0.20 at 20:00 UTC?", 20_000_000, uint64(block.timestamp + 1 days), uint64(block.timestamp + 2 days));
    }

    function test_yesWinnersShareThePot() public {
        uint256 id = _market();
        vm.prank(alice); pr.bet(id, true, 1_000 ether);
        vm.prank(carol); pr.bet(id, true, 3_000 ether);
        vm.prank(bob); pr.bet(id, false, 4_000 ether);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vm.expectRevert(bytes("Predict: closed"));
        pr.bet(id, true, 1 ether);
        vm.prank(bot);
        vm.expectRevert(bytes("Predict: too early"));
        pr.resolve(id, 21_000_000);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vm.expectRevert(bytes("Predict: not oracle"));
        pr.resolve(id, 21_000_000);
        vm.prank(bot);
        pr.resolve(id, 21_000_000); // $0.21 > $0.20: YES
        assertEq(kings.balanceOf(address(0xFEE)), 160 ether); // 2% of 8,000
        assertEq(pr.claimable(id, alice), 1_960 ether);        // 1/4 of 7,840
        assertEq(pr.claimable(id, carol), 5_880 ether);
        assertEq(pr.claimable(id, bob), 0);
        vm.prank(alice); pr.claim(id);
        vm.prank(carol); pr.claim(id);
        vm.prank(alice);
        vm.expectRevert(bytes("Predict: nothing to claim"));
        pr.claim(id);
        assertEq(kings.balanceOf(address(pr)), 0);
    }

    function test_oneSidedRefunds() public {
        uint256 id = _market();
        vm.prank(alice); pr.bet(id, true, 1_000 ether);
        vm.warp(block.timestamp + 2 days);
        vm.prank(bot);
        pr.resolve(id, 10_000_000); // NO won but nobody backed NO: refund
        assertEq(uint256(pr.get(id).state), uint256(KingPredict.State.Refund));
        uint256 b = kings.balanceOf(alice);
        vm.prank(alice); pr.claim(id);
        assertEq(kings.balanceOf(alice) - b, 1_000 ether);
    }

    function test_expiresIfOracleSilent() public {
        uint256 id = _market();
        vm.prank(alice); pr.bet(id, true, 500 ether);
        vm.prank(bob); pr.bet(id, false, 700 ether);
        vm.warp(block.timestamp + 2 days + 1 days);
        vm.expectRevert(bytes("Predict: not expired"));
        pr.expire(id);
        vm.warp(block.timestamp + 7 days);
        pr.expire(id);
        vm.prank(bob); pr.claim(id);
        assertEq(kings.balanceOf(bob), 10_000 ether);
        (uint256[] memory ids,) = pr.page(0, 10);
        assertEq(ids.length, 1);
        assertEq(pr.idsOf(alice).length, 1);
    }
}
