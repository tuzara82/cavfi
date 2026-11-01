// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KingGames2} from "../src/KingGames2.sol";

contract KingGames2Test is Test {
    KingGames2 g;
    address owner = address(0xA11CE);
    address house = address(0xB07);
    address alice = address(0xA1);
    bytes32[] chain;
    uint256 constant N = 3000;
    uint256 anchorRound;

    function setUp() public {
        vm.warp(1_800_000_000);
        g = new KingGames2(owner, house);
        vm.deal(address(g), 1000 ether);
        vm.deal(alice, 1000 ether);
        chain.push(keccak256("s"));
        for (uint256 i = 1; i <= N; i++) chain.push(keccak256(abi.encodePacked(chain[i - 1])));
        vm.prank(house);
        g.setAnchor(chain[N], N);
        anchorRound = 1_800_000_000 / 30;
        vm.warp(block.timestamp + 30);
    }

    function seedOf(uint256 r) internal view returns (bytes32) { return chain[N - (r - anchorRound)]; }

    function settleRound(uint256 r) internal { vm.warp((r + 1) * 30); g.reveal(seedOf(r)); }

    function bet(uint8 game, uint16 pick, bool over, uint256 stake) internal returns (uint256 id) {
        vm.prank(alice);
        id = g.play{value: stake}(game, pick, over);
    }

    function testEveryGameSettlesWithTheRightPayout() public {
        uint256 r = vm.getBlockTimestamp() / 30;
        uint256[6] memory ids;
        ids[0] = bet(0, 1, false, 1 ether);
        ids[1] = bet(1, 30, false, 1 ether);
        ids[2] = bet(2, 250, false, 1 ether);
        ids[3] = bet(3, 0, false, 1 ether);
        ids[4] = bet(4, 2, false, 0.5 ether);
        uint8 card = g.cardOf(alice);
        ids[5] = bet(5, card <= 7 ? 1 : 0, false, 1 ether);
        uint256 before = alice.balance;
        settleRound(r);
        uint256 paidSum;
        for (uint256 i; i < 6; i++) {
            KingGames2.Bet memory b = g.get(ids[i]);
            assertTrue(b.status == KingGames2.Status.Won || b.status == KingGames2.Status.Lost);
            uint256 rnd = uint256(keccak256(abi.encodePacked(seedOf(r), ids[i])));
            // recompute independently
            uint256 want;
            if (i == 0) want = (rnd % 100 + 1) > 50 ? 1.96 ether : 0;
            if (i == 1) want = (rnd % 100 + 1) < 30 ? uint256(1 ether) * 98 / 29 : 0;
            if (i == 2) { uint256 m = 98e6 / (rnd % 1e6 + 1); want = m >= 250 ? 2.5 ether : 0; }
            if (i == 3) want = 1 ether * g.wheel(rnd % 20) / 100;
            if (i == 4) { uint256 x = rnd & 0xff; uint256 c; for (; x != 0; x >>= 1) c += x & 1; want = 0.5 ether * g.plinko(2, c) / 100; }
            if (i == 5) { uint256 nx = rnd % 13 + 1; bool hi = card <= 7; uint256 w = hi ? 13 - card : card - 1; want = (hi ? nx > card : nx < card) ? uint256(1 ether) * 1274 / (100 * w) : 0; }
            assertEq(b.payout, want, "payout");
            paidSum += want;
        }
        assertEq(alice.balance - before, paidSum);
        assertEq(g.reserved(), 0);
        // the drawn HILO card is the next card
        assertEq(g.cardOf(alice), uint8(g.get(ids[5]).result));
    }

    function testReturnToPlayer() public view {
        // average payout per 1 DOGE over many random numbers, every game close to 98%
        KingGames2.Bet memory b;
        b.stake = 1e18;
        uint256 n = 20000;
        uint256[6] memory sum;
        for (uint256 j; j < n; j++) {
            uint256 rnd = uint256(keccak256(abi.encode(j)));
            b.game = 0; b.pick = 0; b.payout = 1.96e18; (, uint256 p) = g.outcome(b, rnd); sum[0] += p;
            b.game = 1; b.pick = 50; b.over = true; b.payout = uint96(uint256(1e18) * 98 / 50); (, p) = g.outcome(b, rnd); sum[1] += p;
            b.game = 2; b.pick = 300; (, p) = g.outcome(b, rnd); sum[2] += p;
            b.game = 3; (, p) = g.outcome(b, rnd); sum[3] += p;
            b.game = 4; b.pick = 1; (, p) = g.outcome(b, rnd); sum[4] += p;
            b.game = 5; b.pick = 1; b.card = 4; b.payout = uint96(uint256(1e18) * 1274 / 900); (, p) = g.outcome(b, rnd); sum[5] += p;
        }
        for (uint256 i; i < 6; i++) {
            uint256 rtp = sum[i] / n / 1e14;   // basis points
            assertGt(rtp, 9300, "rtp low");
            assertLt(rtp, 10300, "rtp high");
        }
    }

    function testInvalidBets() public {
        vm.startPrank(alice);
        vm.expectRevert("Games: bet");
        g.play{value: 1 ether}(2, 100, false);     // limbo below 1.01x
        vm.expectRevert("Games: bet");
        g.play{value: 1 ether}(2, 10001, false);
        vm.expectRevert("Games: bet");
        g.play{value: 1 ether}(4, 3, false);       // no such risk
        vm.expectRevert("Games: bet");
        g.play{value: 1 ether}(6, 0, false);       // no such game
        vm.stopPrank();
        uint8 c = g.cardOf(alice);
        if (c == 13 || c == 1) {
            vm.prank(alice);
            vm.expectRevert("Games: bet");
            g.play{value: 1 ether}(5, c == 13 ? 1 : 0, false);
        }
    }

    function testBankrollCap() public {
        // free 1000, risk 10%: limbo 100x may stake at most 100/99 DOGE
        uint256 m = g.maxStakeFor(2, 10000, false, alice);
        assertApproxEqAbs(m, uint256(100 ether) * 1 ether / 99 ether, 1e9);
        vm.prank(alice);
        vm.expectRevert("Games: bankroll");
        g.play{value: 2 ether}(2, 10000, false);
        bet(2, 10000, false, 1 ether);
    }

    function testTimeoutPaysTheMaximum() public {
        uint256 id = bet(3, 0, false, 1 ether);
        vm.warp(block.timestamp + 30 + 1 hours + 1);
        uint256 before = alice.balance;
        g.claimTimeout(id);
        assertEq(alice.balance - before, 5 ether);
        assertEq(g.reserved(), 0);
    }

    function testFullRoundGas() public {
        uint256 r = vm.getBlockTimestamp() / 30;
        for (uint256 i; i < 40; i++) bet(uint8(i % 5), i % 5 == 1 ? 50 : i % 5 == 2 ? 200 : i % 5 == 4 ? 1 : 0, true, 0.1 ether);
        vm.warp((r + 1) * 30);
        uint256 g0 = gasleft();
        g.reveal(seedOf(r));
        assertLt(g0 - gasleft(), 4_000_000);
        assertEq(g.reserved(), 0);
    }
}
