// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RedstoneFixtures} from "./KingV6.t.sol";
import {KingPredict3, IRedStoneFeed} from "../src/KingPredict3.sol";
import {KingGuess3, IRedStoneFeedG} from "../src/KingGuess3.sol";
import {KingS} from "../src/KingS.sol";

contract MockFeed {
    int256 public answer;
    uint256 public updatedAt;
    function set(int256 a, uint256 t) external { answer = a; updatedAt = t; }
    function decimals() external pure returns (uint8) { return 8; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) { return (1, answer, updatedAt, updatedAt, 1); }
}

contract KingPredict3Test is RedstoneFixtures {
    KingS kings;
    KingPredict3 p;
    MockFeed feed;
    address bot = address(0xB07);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.warp(T19 + 120);
        kings = new KingS(address(this), 1_000_000 ether);
        feed = new MockFeed();
        feed.set(7_650_000, T19 - 3600);
        p = new KingPredict3(address(this), kings, bot, 90, IRedStoneFeed(address(feed)));
        for (uint256 i; i < 2; i++) {
            address u = i == 0 ? alice : bob;
            kings.transfer(u, 1000 ether);
            vm.prank(u); kings.approve(address(p), type(uint256).max);
        }
    }

    function _fixed() internal returns (uint256 id) {
        vm.prank(bot);
        id = p.create("Will DOGE be above $0.0770 at 20:00 UTC?", 7_700_000, T20 - 1800, T20);
        vm.prank(alice); p.bet(id, true, 100 ether);
        vm.prank(bob); p.bet(id, false, 50 ether);
    }

    function test_fixedMarketUsesFeedValueAtResolveTime() public {
        uint256 id = _fixed();
        assertEq(id, 90);
        assertFalse(p.byPull(id));
        feed.set(7_713_139, T20 - 200);   // last update before 20:00: that is the price at 20:00
        vm.warp(T20 + 5);
        // a payload appended to the call is ignored: the source is fixed per market
        (bool ok, bytes memory ret) = callWith(address(p), abi.encodeCall(KingPredict3.resolve, (id)), P19);
        assertTrue(ok, revertMsg(ret));
        KingPredict3.Market memory m = p.get(id);
        assertEq(m.price, 7_713_139);
        assertTrue(m.yesWon);
        vm.prank(alice); p.claim(id);
        assertEq(kings.balanceOf(alice), 900 ether + 147 ether);
    }

    function test_feedUpdatedAfterOrTooOldCannotDecide() public {
        uint256 id = _fixed();
        vm.warp(T20 + 30);
        feed.set(7_800_000, T20 + 10);   // updated after 20:00: price at 20:00 unknown
        vm.expectRevert(bytes("Predict: feed updated after that moment"));
        p.resolve(id);
        feed.set(7_800_000, T20 - 26 hours);
        vm.expectRevert(bytes("Predict: feed too old"));
        p.resolve(id);
        vm.expectRevert(bytes("Predict: not expired"));
        p.expire(id);
        vm.warp(T20 + 1 days + 1);
        p.expire(id);
        vm.prank(bob); p.claim(id);
        assertEq(kings.balanceOf(bob), 1000 ether);
    }

    function test_upDownStillUsesSignedDataForTheExactSecond() public {
        vm.prank(bot);
        (bool ok, bytes memory ret) = callWith(address(p), abi.encodeCall(KingPredict3.createUpDown, ("Hourly?", T19, T20 - 600, T20)), P19);
        assertTrue(ok, revertMsg(ret));
        uint256 id = abi.decode(ret, (uint256));
        assertTrue(p.byPull(id));
        assertEq(p.get(id).strike, 7702066);
        vm.prank(alice); p.bet(id, true, 10 ether);
        vm.prank(bob); p.bet(id, false, 10 ether);
        vm.warp(T20 + 30);
        feed.set(1, T20 - 1);   // the feed is not used for this market
        (ok, ret) = callWith(address(p), abi.encodeCall(KingPredict3.resolve, (id)), "");
        assertFalse(ok);
        (ok, ret) = callWith(address(p), abi.encodeCall(KingPredict3.resolve, (id)), P20);
        assertTrue(ok, revertMsg(ret));
        assertEq(p.get(id).price, 7713139);
    }
}

contract KingGuess3Test is RedstoneFixtures {
    KingS kings;
    KingGuess3 g;
    MockFeed feed;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.warp(uint256(DAY) * 1 days + 10 hours);
        kings = new KingS(address(this), 1_000_000 ether);
        feed = new MockFeed();
        g = new KingGuess3(address(this), kings, 10_000 ether, IRedStoneFeedG(address(feed)));
        kings.transfer(address(g), 25_000 ether);
    }

    function test_settleWithFeed() public {
        vm.prank(alice); g.guess(7_713_000);
        vm.prank(bob); g.guess(7_600_000);
        feed.set(7_713_139, T20 - 3 hours);
        vm.warp(T20 - 1);
        vm.expectRevert(bytes("Guess: too early"));
        g.settle(DAY);
        vm.warp(T20 + 20);
        g.settle(DAY);
        assertEq(g.dayInfo(DAY).winner, alice);
        assertEq(g.dayInfo(DAY).price, 7_713_139);
        assertEq(kings.balanceOf(alice), 10_000 ether);
    }

    function test_feedUpdatedAfter20OrLate() public {
        vm.prank(alice); g.guess(7_713_000);
        vm.warp(T20 + 20);
        feed.set(7_700_000, T20 + 5);
        vm.expectRevert(bytes("Guess: feed updated after 20:00 UTC"));
        g.settle(DAY);
        feed.set(7_700_000, T20 - 60);
        vm.warp(T20 + 1 days + 1);
        vm.expectRevert(bytes("Guess: too late"));
        g.settle(DAY);
    }
}
