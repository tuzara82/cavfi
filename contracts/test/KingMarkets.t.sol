// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KingMarkets} from "../src/KingMarkets.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract KM is ERC20 { constructor() ERC20("KingS", "KINGS") { _mint(msg.sender, 1e30); } }

contract KingMarketsTest is Test {
    KingMarkets mk;
    KM k;
    address bot = address(0xB07);
    address fee = address(0xFEE);
    address a = address(0xA1);
    address b = address(0xB0B);
    address c = address(0xC0C);

    function setUp() public {
        vm.warp(1_800_000_000);
        k = new KM();
        mk = new KingMarkets(address(this), IERC20(address(k)), bot);
        mk.setFeeTo(fee);
        for (uint256 i; i < 3; i++) {
            address u = [a, b, c][i];
            k.transfer(u, 100_000 ether);
            vm.prank(u); k.approve(address(mk), type(uint256).max);
        }
        string[] memory o = new string[](3); o[0] = "Arsenal"; o[1] = "Draw"; o[2] = "Chelsea";
        vm.prank(bot);
        mk.create("football", "Arsenal vs Chelsea", o, "Final score after 90 min, ESPN", uint64(block.timestamp + 1 days), uint64(block.timestamp + 1 days + 3 hours));
    }

    function bets() internal {
        vm.prank(a); mk.bet(0, 0, 300 ether);
        vm.prank(b); mk.bet(0, 2, 600 ether);
        vm.prank(c); mk.bet(0, 0, 100 ether);
    }

    function testProposeFinalizeClaim() public {
        bets();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(a); vm.expectRevert("Markets: closed"); mk.bet(0, 1, 1 ether);
        vm.prank(bot); vm.expectRevert("Markets: too early"); mk.propose(0, 0, "x");
        vm.warp(vm.getBlockTimestamp() + 3 hours);
        vm.prank(a); vm.expectRevert("Markets: not resolver"); mk.propose(0, 0, "x");
        vm.prank(bot); mk.propose(0, 0, "espn.com/game/1");
        vm.expectRevert("Markets: not final yet"); mk.finalize(0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        mk.finalize(0);
        // pot 1000, fee 20 -> 980 shared 3:1
        assertEq(k.balanceOf(fee), 20 ether);
        assertEq(mk.claimable(0, a), 735 ether);
        assertEq(mk.claimable(0, c), 245 ether);
        assertEq(mk.claimable(0, b), 0);
        vm.prank(a); mk.claim(0);
        vm.prank(c); mk.claim(0);
        vm.prank(a); vm.expectRevert("Markets: nothing to claim"); mk.claim(0);
    }

    function testDisputeOverturned() public {
        bets();
        vm.warp(vm.getBlockTimestamp() + 1 days + 3 hours);
        vm.prank(bot); mk.propose(0, 0, "wrong");
        uint256 before = k.balanceOf(b);
        vm.prank(b); mk.dispute(0);
        assertEq(before - k.balanceOf(b), 1_000 ether);
        vm.expectRevert("Markets: not final yet"); mk.finalize(0);
        mk.rule(0, 2);
        assertEq(k.balanceOf(b), before);                 // bond back
        assertEq(mk.claimable(0, b), 980 ether);
    }

    function testDisputeUpheldBondToFee() public {
        bets();
        vm.warp(vm.getBlockTimestamp() + 1 days + 3 hours);
        vm.prank(bot); mk.propose(0, 0, "right");
        vm.prank(b); mk.dispute(0);
        mk.rule(0, 0);
        assertEq(k.balanceOf(fee), 1_020 ether);
    }

    function testVoidAndExpiry() public {
        bets();
        vm.warp(vm.getBlockTimestamp() + 1 days + 3 hours);
        vm.prank(bot); mk.propose(0, 255, "match postponed");
        vm.warp(vm.getBlockTimestamp() + 1 days);
        mk.finalize(0);
        assertEq(mk.claimable(0, b), 600 ether);
        assertEq(k.balanceOf(fee), 0);
    }

    function testExpireNoProposal() public {
        bets();
        vm.warp(vm.getBlockTimestamp() + 1 days + 3 hours + 3 days + 1);
        mk.expire(0);
        assertEq(mk.claimable(0, a), 300 ether);
    }

    function testExpireUnruledDispute() public {
        bets();
        vm.warp(vm.getBlockTimestamp() + 1 days + 3 hours);
        vm.prank(bot); mk.propose(0, 0, "x");
        uint256 before = k.balanceOf(c);
        vm.prank(c); mk.dispute(0);
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        mk.expire(0);
        assertEq(k.balanceOf(c), before);
        assertEq(mk.claimable(0, c), 100 ether);
    }

    function testOneSidedRefund() public {
        vm.prank(a); mk.bet(0, 0, 300 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days + 3 hours);
        vm.prank(bot); mk.propose(0, 0, "x");
        vm.warp(vm.getBlockTimestamp() + 1 days);
        mk.finalize(0);
        assertEq(mk.claimable(0, a), 300 ether);
    }

    function testPageAndViews() public {
        bets();
        (uint256[] memory ids, KingMarkets.Market[] memory items, uint256[][] memory pool) = mk.page(0, 10);
        assertEq(ids.length, 1);
        assertEq(items[0].outcomes.length, 3);
        assertEq(pool[0][0], 400 ether);
        assertEq(mk.stakesOf(0, b)[2], 600 ether);
        assertEq(mk.idsOf(a).length, 1);
    }
}
