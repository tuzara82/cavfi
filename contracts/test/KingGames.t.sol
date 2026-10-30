// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KingGames} from "../src/KingGames.sol";

contract Rejector { receive() external payable { revert(); } function play(KingGames g) external payable { g.play{value: msg.value}(0, 0, false); } }

contract KingGamesTest is Test {
    KingGames g;
    address owner = address(0xA11CE);
    address house = address(0xB07);
    address alice = address(0xA1);
    address bob = address(0xB0B);
    bytes32 secret = keccak256("secret");
    uint256 constant N = 5000;
    bytes32[] chain;   // chain[i] = keccak^i(secret)

    function setUp() public {
        vm.warp(1_800_000_000);
        g = new KingGames(owner, house);
        vm.deal(address(g), 1000 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        chain.push(secret);
        for (uint256 i = 1; i <= N; i++) chain.push(keccak256(abi.encodePacked(chain[i - 1])));
        vm.prank(house);
        g.setAnchor(chain[N], N);
        vm.warp(block.timestamp + 30);
    }

    function seedOf(uint256 r) internal view returns (bytes32) {
        uint256 a = 1_800_000_000 / 30;   // anchor round
        return chain[N - (r - a)];
    }

    function testCoinFlipFlow() public {
        vm.prank(alice);
        uint256 id = g.play{value: 1 ether}(0, 0, false);
        KingGames.Bet memory b = g.get(id);
        assertEq(b.payout, 1.96 ether);
        assertEq(g.reserved(), 1.96 ether);
        vm.expectRevert("Games: round open");
        g.reveal(seedOf(b.round));
        vm.warp(block.timestamp + 31);
        vm.expectRevert("Games: bad seed");
        g.reveal(keccak256("x"));
        uint256 before = alice.balance;
        g.reveal(seedOf(b.round));
        b = g.get(id);
        assertTrue(b.status == KingGames.Status.Won || b.status == KingGames.Status.Lost);
        assertEq(g.reserved(), 0);
        uint8 roll = uint8(uint256(keccak256(abi.encodePacked(seedOf(b.round), id))) % 100 + 1);
        assertEq(b.roll, roll);
        if (roll <= 50) assertEq(alice.balance - before, 1.96 ether);
        else assertEq(alice.balance, before);
    }

    function testDiceAndSkippedRounds() public {
        vm.warp(block.timestamp + 300);   // 10 empty rounds
        vm.prank(alice);
        uint256 a = g.play{value: 2 ether}(1, 50, true);   // roll > 50: 50 wins
        vm.prank(bob);
        uint256 c = g.play{value: 1 ether}(1, 11, false);  // roll < 11: 10 wins -> 9.8x
        assertEq(g.get(c).payout, 9.8 ether);
        vm.warp(block.timestamp + 95);
        vm.prank(bob);
        uint256 d = g.play{value: 1 ether}(0, 1, false);
        vm.warp(block.timestamp + 30);
        uint256[] memory pr = g.pendingRounds();
        assertEq(pr.length, 2);
        // out of order: the second round cannot be revealed first
        vm.expectRevert("Games: bad seed");
        g.reveal(seedOf(pr[1]));
        g.reveal(seedOf(pr[0]));
        assertTrue(g.get(a).status != KingGames.Status.Pending);
        assertTrue(g.get(c).status != KingGames.Status.Pending);
        assertTrue(g.get(d).status == KingGames.Status.Pending);
        g.reveal(seedOf(pr[1]));
        assertTrue(g.get(d).status != KingGames.Status.Pending);
        assertEq(g.reserved(), 0);
    }

    function testInvalidBets() public {
        vm.startPrank(alice);
        vm.expectRevert("Games: bet");
        g.play{value: 1 ether}(0, 2, false);
        vm.expectRevert("Games: bet");
        g.play{value: 1 ether}(1, 1, false);
        vm.expectRevert("Games: bet");
        g.play{value: 1 ether}(1, 99, true);   // 1 win: too long a shot
        vm.expectRevert("Games: stake");
        g.play{value: 0.01 ether}(0, 0, false);
        vm.stopPrank();
    }

    function testBankrollLimit() public {
        vm.deal(alice, 1000 ether);
        // free 1000: risk cap 50 DOGE; 2 wins at 49x: stake*(47)/... net risk = stake*48 -> max ~1.04
        uint256 m = g.maxStakeFor(1, 3, false);
        assertApproxEqAbs(m, uint256(50 ether) * 2 / 96, 1);
        vm.prank(alice);
        vm.expectRevert("Games: bankroll");
        g.play{value: 2 ether}(1, 3, false);
        vm.prank(alice);
        g.play{value: 1 ether}(1, 3, false);
    }

    function testTimeoutAndOffline() public {
        vm.prank(alice);
        uint256 id = g.play{value: 1 ether}(0, 1, false);
        vm.warp(block.timestamp + 30 + 10 minutes + 1);
        assertFalse(g.houseOnline());
        vm.prank(bob);
        vm.expectRevert("Games: house offline");
        g.play{value: 1 ether}(0, 1, false);
        vm.expectRevert("Games: not late");
        g.claimTimeout(id);
        vm.warp(block.timestamp + 1 hours);
        uint256 before = alice.balance;
        g.claimTimeout(id);
        assertEq(alice.balance - before, 1.96 ether);
        assertEq(g.reserved(), 0);
        // late reveal still moves the chain on and skips the claimed bet
        g.reveal(seedOf(g.get(id).round));
        assertTrue(g.get(id).status == KingGames.Status.TimeoutWon);
        assertTrue(g.houseOnline());
    }

    function testWithdrawKeepsReserved() public {
        vm.prank(alice);
        g.play{value: 10 ether}(0, 0, false);
        uint256 f = g.free();
        assertEq(f, 1010 ether - 19.6 ether);
        vm.prank(owner);
        vm.expectRevert("Games: reserved");
        g.withdraw(f + 1, payable(owner));
        vm.prank(owner);
        g.withdraw(f, payable(owner));
        assertEq(address(g).balance, 19.6 ether);
    }

    function testRejectorGetsOwed() public {
        Rejector r = new Rejector();
        vm.deal(address(this), 10 ether);
        // find a winning round for heads by trying rounds
        uint256 id = g.count();
        uint256 t = vm.getBlockTimestamp();
        for (uint256 k; k < 50; k++) {
            uint8 roll = uint8(uint256(keccak256(abi.encodePacked(seedOf(t / 30), id))) % 100 + 1);
            if (roll <= 50) break;
            t += 30;
        }
        vm.warp(t);
        r.play{value: 1 ether}(g);
        vm.warp(t + 30);
        g.reveal(seedOf(t / 30));
        assertEq(g.owed(address(r)), 1.96 ether);
    }

    function testReanchorOnlyWhenIdle() public {
        vm.prank(alice);
        g.play{value: 1 ether}(0, 0, false);
        vm.prank(house);
        vm.expectRevert("Games: rounds pending");
        g.setAnchor(keccak256("new"), 10);
        vm.prank(alice);
        vm.expectRevert("Games: not house");
        g.setAnchor(keccak256("new"), 10);
    }

    function testRoundFull() public {
        for (uint256 i; i < 40; i++) { vm.prank(alice); g.play{value: 0.1 ether}(0, 0, false); }
        vm.prank(bob);
        vm.expectRevert("Games: round full");
        g.play{value: 0.1 ether}(0, 0, false);
        vm.warp(block.timestamp + 30);
        uint256 gasBefore = gasleft();
        g.reveal(seedOf(g.get(0).round));
        assertLt(gasBefore - gasleft(), 3_000_000);
        assertEq(g.reserved(), 0);
    }
}
