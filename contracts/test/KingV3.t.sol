// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KingS} from "../src/KingS.sol";
import {WDOGE} from "../src/WDOGE.sol";
import {KingFactory} from "../src/KingFactory.sol";
import {KingRouter} from "../src/KingRouter.sol";
import {KingDCA} from "../src/KingDCA.sol";
import {KingQuests} from "../src/KingQuests.sol";
import {KingRaffle} from "../src/KingRaffle.sol";

contract KingDCATest is Test {
    KingS kings;
    WDOGE wdoge;
    KingFactory factory;
    KingRouter router;
    KingDCA dca;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address keeper = address(0xBEEF);

    function setUp() public {
        wdoge = new WDOGE();
        factory = new KingFactory(address(this), address(0));
        router = new KingRouter(address(factory), address(wdoge));
        dca = new KingDCA(address(this), address(router), address(wdoge));
        dca.setKeeper(keeper, true);
        kings = new KingS(alice, 1_000_000_000 ether);
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 100 ether);
        vm.startPrank(alice);
        kings.approve(address(router), type(uint256).max);
        router.addLiquidityETH{value: 100 ether}(address(kings), 1_000_000 ether, 0, 0, alice, block.timestamp);
        vm.stopPrank();
    }

    function _p(address a, address b) internal pure returns (address[] memory p) { p = new address[](2); p[0] = a; p[1] = b; }

    function test_nativePlanRunsOnScheduleAndPaysTip() public {
        vm.prank(bob);
        uint256 id = dca.createNative{value: 3 ether}(address(kings), 1 ether, 3, 1 hours, 0);
        assertEq(bob.balance, 97 ether);
        // first part is due right away
        vm.prank(keeper);
        uint256 out1 = dca.execute(id, _p(address(wdoge), address(kings)));
        assertGt(out1, 9_000 ether);
        assertEq(kings.balanceOf(bob), out1);
        assertEq(wdoge.balanceOf(keeper), 0.001 ether, "0.1% tip");
        // second part not due yet
        vm.prank(keeper);
        vm.expectRevert(bytes("KingDCA: NOT_DUE"));
        dca.execute(id, _p(address(wdoge), address(kings)));
        assertEq(dca.due(0, 10).length, 0);
        vm.warp(block.timestamp + 1 hours);
        assertEq(dca.due(0, 10).length, 1);
        vm.prank(keeper);
        dca.execute(id, _p(address(wdoge), address(kings)));
        // after a long pause there is no burst: one part, then one interval later
        vm.warp(block.timestamp + 10 hours);
        vm.prank(keeper);
        dca.execute(id, _p(address(wdoge), address(kings)));
        KingDCA.Plan memory p = dca.get(id);
        assertFalse(p.active);
        assertEq(p.buysLeft, 0);
        assertEq(p.spent, 3 ether);
        assertEq(p.received, kings.balanceOf(bob));
        assertEq(wdoge.balanceOf(address(dca)), 0, "nothing left behind");
    }

    function test_onlyKeeperAndPriceFloor() public {
        vm.prank(bob);
        uint256 id = dca.createNative{value: 2 ether}(address(kings), 1 ether, 2, 1 hours, 20_000 ether); // floor above market
        vm.prank(bob);
        vm.expectRevert(bytes("KingDCA: NOT_KEEPER"));
        dca.execute(id, _p(address(wdoge), address(kings)));
        vm.prank(keeper);
        vm.expectRevert();
        dca.execute(id, _p(address(wdoge), address(kings)));
        vm.prank(keeper);
        vm.expectRevert(bytes("KingDCA: PATH"));
        dca.execute(id, _p(address(kings), address(wdoge)));
    }

    function test_cancelRefundsUnusedParts() public {
        vm.prank(bob);
        uint256 id = dca.createNative{value: 4 ether}(address(kings), 1 ether, 4, 1 hours, 0);
        vm.prank(keeper);
        dca.execute(id, _p(address(wdoge), address(kings)));
        vm.prank(alice);
        vm.expectRevert(bytes("KingDCA: NOT_OWNER"));
        dca.cancel(id);
        uint256 before = bob.balance;
        vm.prank(bob);
        dca.cancel(id);
        assertEq(bob.balance - before, 3 ether, "3 unused parts back as DOGE");
        vm.prank(bob);
        vm.expectRevert(bytes("KingDCA: NOT_ACTIVE"));
        dca.cancel(id);
    }

    function test_tokenPlanSellsForNativeDoge() public {
        vm.prank(alice);
        kings.transfer(bob, 30_000 ether);
        vm.startPrank(bob);
        kings.approve(address(dca), 30_000 ether);
        uint256 id = dca.create(address(kings), address(wdoge), 10_000 ether, 3, 1 hours, 0, true);
        vm.stopPrank();
        uint256 before = bob.balance;
        vm.prank(keeper);
        uint256 out = dca.execute(id, _p(address(kings), address(wdoge)));
        assertEq(bob.balance - before, out, "paid out as DOGE");
        (uint256[] memory ids,) = dca.plansOf(bob);
        assertEq(ids.length, 1);
    }

    function test_rules() public {
        vm.startPrank(bob);
        vm.expectRevert(bytes("KingDCA: VALUE"));
        dca.createNative{value: 1 ether}(address(kings), 1 ether, 2, 1 hours, 0);
        vm.expectRevert(bytes("KingDCA: INTERVAL"));
        dca.createNative{value: 2 ether}(address(kings), 1 ether, 2, 60, 0);
        vm.expectRevert(bytes("KingDCA: SIZE"));
        dca.createNative{value: 0}(address(kings), 0, 2, 1 hours, 0);
        vm.stopPrank();
    }
}

contract KingQuestsTest is Test {
    KingQuests q;
    address bot = address(0xB07);
    address a = address(0xA);
    address b = address(0xB);

    function setUp() public {
        q = new KingQuests(address(this));
        q.setAttester(bot, true);
        vm.warp(100 days);
    }

    function _one(address u) internal pure returns (address[] memory x) { x = new address[](1); x[0] = u; }
    function _d(uint8 v) internal pure returns (uint8[] memory x) { x = new uint8[](1); x[0] = v; }

    function test_streakBadgeAndRules() public {
        uint32 t = q.today();
        vm.prank(a);
        vm.expectRevert(bytes("Quests: not attester"));
        q.record(t - 1, _one(a), _d(3));
        vm.prank(bot);
        vm.expectRevert(bytes("Quests: day"));
        q.record(t, _one(a), _d(3));
        // 7 full days in a row, recorded one day after each
        uint256 now_ = block.timestamp;
        for (uint256 i; i < 7; i++) {
            now_ += 1 days;
            vm.warp(now_);
            uint32 day = q.today() - 1;
            vm.prank(bot);
            q.record(day, _one(a), _d(3));
        }
        (uint256 streak, uint256 best, uint256 full, uint256 quests, bool badge,) = q.info(a);
        assertEq(streak, 7);
        assertEq(best, 7);
        assertEq(full, 7);
        assertEq(quests, 21);
        assertTrue(badge);
        // same day again is ignored
        uint32 y = q.today() - 1;
        vm.prank(bot);
        q.record(y, _one(a), _d(3));
        (,,, quests,,) = q.info(a);
        assertEq(quests, 21);
        // soulbound
        vm.prank(a);
        vm.expectRevert(bytes("Quests: soulbound"));
        q.safeTransferFrom(a, b, 1, 1, "");
    }

    function test_partialDayBreaksStreak() public {
        uint256 now_ = block.timestamp;
        now_ += 1 days; vm.warp(now_);
        { uint32 d0 = q.today() - 1; vm.prank(bot); q.record(d0, _one(b), _d(3)); }
        now_ += 1 days; vm.warp(now_);
        { uint32 d0 = q.today() - 1; vm.prank(bot); q.record(d0, _one(b), _d(2)); }
        now_ += 1 days; vm.warp(now_);
        { uint32 d0 = q.today() - 1; vm.prank(bot); q.record(d0, _one(b), _d(3)); }
        (uint256 streak, uint256 best,, uint256 quests,, uint8 yday) = q.info(b);
        assertEq(streak, 1);
        assertEq(best, 1);
        assertEq(quests, 8);
        assertEq(yday, 3);
        // a gap of two days ends the streak in info()
        now_ += 3 days; vm.warp(now_);
        (streak,,,,,) = q.info(b);
        assertEq(streak, 0);
    }
}

contract KingRaffleTest is Test {
    KingS kings;
    KingRaffle r;
    address bot = address(0xB07);
    address[] users;

    function setUp() public {
        kings = new KingS(address(this), 1_000_000 ether);
        r = new KingRaffle(address(this), kings);
        r.setAttester(bot, true);
        kings.approve(address(r), type(uint256).max);
        r.fund(10_000 ether);
        for (uint160 i = 1; i <= 5; i++) users.push(address(0x1000 + i));
    }

    function _tickets(uint256 each) internal {
        uint256[] memory c = new uint256[](users.length);
        for (uint256 i; i < c.length; i++) c[i] = each + i;
        vm.prank(bot);
        r.addTickets(users, c);
    }

    function test_weeklyDrawPaysThreeDistinctWinners() public {
        _tickets(1);
        address[] memory one = new address[](1); one[0] = users[0];
        uint256[] memory c = new uint256[](1); c[0] = 2;
        vm.prank(users[0]);
        vm.expectRevert(bytes("Raffle: not attester"));
        r.addTickets(one, c);
        vm.expectRevert(bytes("Raffle: not ended"));
        r.close();
        vm.warp(block.timestamp + 7 days);
        r.close();
        vm.expectRevert(bytes("Raffle: not ready"));
        r.draw();
        vm.roll(block.number + 4);
        r.draw();
        KingRaffle.Round memory g = r.getRound(1);
        assertTrue(g.drawn);
        assertEq(g.pot, 10_000 ether);
        assertTrue(g.winners[0] != g.winners[1] && g.winners[1] != g.winners[2] && g.winners[0] != g.winners[2]);
        assertEq(g.prizes[0], 5_000 ether);
        assertEq(g.prizes[1], 3_000 ether);
        assertEq(g.prizes[2], 2_000 ether);
        assertEq(kings.balanceOf(g.winners[0]), 5_000 ether);
        assertEq(kings.balanceOf(address(r)), 0);
        (uint256 id,,, uint256 tt,,,) = r.current();
        assertEq(id, 2);
        assertEq(tt, 0);
    }

    function test_emptyRoundRollsThePot() public {
        vm.warp(block.timestamp + 7 days);
        r.close();
        vm.roll(block.number + 4);
        r.draw();
        assertEq(kings.balanceOf(address(r)), 10_000 ether);
        // tickets can't be added to a closed round
        (uint256 id,,,,,,) = r.current();
        assertEq(id, 2);
    }

    function test_singlePlayerGetsHalfRestRolls() public {
        address[] memory one = new address[](1); one[0] = users[0];
        uint256[] memory c = new uint256[](1); c[0] = 3;
        vm.prank(bot);
        r.addTickets(one, c);
        vm.warp(block.timestamp + 7 days);
        r.close();
        vm.roll(block.number + 4);
        r.draw();
        assertEq(kings.balanceOf(users[0]), 5_000 ether);
        assertEq(kings.balanceOf(address(r)), 5_000 ether);
    }

    function test_staleBlockPicksNewOne() public {
        _tickets(1);
        vm.warp(block.timestamp + 7 days);
        r.close();
        vm.roll(block.number + 400);
        r.draw(); // too old: re-closes
        assertFalse(r.getRound(1).drawn);
        vm.roll(block.number + 4);
        r.draw();
        assertTrue(r.getRound(1).drawn);
    }
}
