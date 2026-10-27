// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KingPredict2} from "../src/KingPredict2.sol";
import {KingGuess2} from "../src/KingGuess2.sol";
import {KingS} from "../src/KingS.sol";

/// Real RedStone primary-prod data packages for DOGE, fetched from oracle-gateway-2 on 2026-10-26:
/// 19:00:00 UTC (1793041200) = $0.07702066 and 20:00:00 UTC (1793044800) = $0.07713139, 3 signers each.
/// Raw packages: test/fixtures/redstone-doge-*.json; payloads built by site/redstone-payload.js.
abstract contract RedstoneFixtures is Test {
    bytes constant P19 = hex"444f474500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000075863201a1799573800000002000000180f665a081970157b1c1d9a00eaf13f8e882f326fd2de1096d460d63bec88db475f10658a4cfca9e4d2f4425c5f194d55f3105516b77568f9ffb657dd8340f351c444f474500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000075863201a179957380000000200000019da3c42f5b1d8dfc571abb2c6149b42c53b9453f2cdcdcd4aaa7d6c94daf97b424f5cfa4abe09e1053b09e91fd79f3cbe085162e13a076a7bad8175ce5e78a621b444f474500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000075863201a17995738000000020000001885f6c3b32ba6cd98a37542dfdca254233a628c1fd9ebb8fd710bc6887684f7a19e23cbb327ae86d771a1836e53ea0d8a6f33a605d43a6c1dfa25b13179af0891b0003000000000002ed57011e0000";
    bytes constant P20 = hex"444f474500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000075b17301a179cc62000000002000000111b0f872875249bdfe8ec4054ec9846d26b7e009aa8fde50d42ace8d16d808915ef7cd7cf2b23017d1261a46ce03a9a8bd22dc81d37ff2895949cf1410deb0611b444f474500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000075b17301a179cc620000000020000001654c9dd82d2d3a10dbc5939da57a0a551e74db0e6d3e59fff631cd32243956145ed7b38d989da0af7be7338405a0cd030eab8217fabb4cd87c57f002ade2cb3b1c444f474500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000075b17301a179cc62000000002000000147fbe89cd921a092a8cb3ca0d721044d3a470a06815ae762c83fb9711b7cfd5853807243997eb6fd57cf66d2f87492c5e2d494be6738cfc22adb4b0248018ce11b0003000000000002ed57011e0000";
    bytes constant P20_TAMPERED = hex"444f4745000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ffffff01a179cc62000000002000000111b0f872875249bdfe8ec4054ec9846d26b7e009aa8fde50d42ace8d16d808915ef7cd7cf2b23017d1261a46ce03a9a8bd22dc81d37ff2895949cf1410deb0611b444f474500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000075b17301a179cc620000000020000001654c9dd82d2d3a10dbc5939da57a0a551e74db0e6d3e59fff631cd32243956145ed7b38d989da0af7be7338405a0cd030eab8217fabb4cd87c57f002ade2cb3b1c444f474500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000075b17301a179cc62000000002000000147fbe89cd921a092a8cb3ca0d721044d3a470a06815ae762c83fb9711b7cfd5853807243997eb6fd57cf66d2f87492c5e2d494be6738cfc22adb4b0248018ce11b0003000000000002ed57011e0000";
    bytes constant P20_TWO = hex"444f474500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000075b17301a179cc62000000002000000111b0f872875249bdfe8ec4054ec9846d26b7e009aa8fde50d42ace8d16d808915ef7cd7cf2b23017d1261a46ce03a9a8bd22dc81d37ff2895949cf1410deb0611b444f474500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000075b17301a179cc620000000020000001654c9dd82d2d3a10dbc5939da57a0a551e74db0e6d3e59fff631cd32243956145ed7b38d989da0af7be7338405a0cd030eab8217fabb4cd87c57f002ade2cb3b1c0002000000000002ed57011e0000";
    bytes constant P20_DUP = hex"444f474500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000075b17301a179cc62000000002000000111b0f872875249bdfe8ec4054ec9846d26b7e009aa8fde50d42ace8d16d808915ef7cd7cf2b23017d1261a46ce03a9a8bd22dc81d37ff2895949cf1410deb0611b444f474500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000075b17301a179cc62000000002000000111b0f872875249bdfe8ec4054ec9846d26b7e009aa8fde50d42ace8d16d808915ef7cd7cf2b23017d1261a46ce03a9a8bd22dc81d37ff2895949cf1410deb0611b444f474500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000075b17301a179cc62000000002000000111b0f872875249bdfe8ec4054ec9846d26b7e009aa8fde50d42ace8d16d808915ef7cd7cf2b23017d1261a46ce03a9a8bd22dc81d37ff2895949cf1410deb0611b0003000000000002ed57011e0000";
    uint64 constant T19 = 1793041200;
    uint64 constant T20 = 1793044800;
    uint32 constant DAY = 20752;   // 2026-10-26

    function callWith(address to, bytes memory data, bytes memory payload) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = to.call(abi.encodePacked(data, payload));
    }

    function revertMsg(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 68 || bytes4(ret) != 0x08c379a0) return "";
        assembly { ret := add(ret, 4) }
        return abi.decode(ret, (string));
    }
}

contract KingPredict2Test is RedstoneFixtures {
    KingS kings;
    KingPredict2 p;
    address bot = address(0xB07);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);
    uint256 constant FIRST = 57;

    function setUp() public {
        vm.warp(T19 + 120);   // 19:02 UTC
        kings = new KingS(address(this), 1_000_000 ether);
        p = new KingPredict2(address(this), kings, bot, FIRST);
        for (uint256 i; i < 2; i++) {
            address u = i == 0 ? alice : bob;
            kings.transfer(u, 1000 ether);
            vm.prank(u); kings.approve(address(p), type(uint256).max);
        }
    }

    function _upDown() internal returns (uint256 id) {
        vm.prank(bot);
        (bool ok, bytes memory ret) = callWith(address(p),
            abi.encodeCall(KingPredict2.createUpDown, ("Hourly: will DOGE be above $0.0770 at 20:00 UTC?", T19, T20 - 600, T20)), P19);
        assertTrue(ok, revertMsg(ret));
        id = abi.decode(ret, (uint256));
    }

    function test_upDownLineAndResolveFromRedStone() public {
        uint256 id = _upDown();
        assertEq(id, FIRST);
        assertEq(p.count(), FIRST + 1);
        assertEq(p.get(id).strike, 7702066);
        assertEq(p.startOf(id), T19);
        vm.prank(alice); p.bet(id, true, 100 ether);
        vm.prank(bob); p.bet(id, false, 50 ether);
        vm.warp(T20 + 30);
        // anyone can resolve
        vm.prank(carol);
        (bool ok, bytes memory ret) = callWith(address(p), abi.encodeCall(KingPredict2.resolve, (id)), P20);
        assertTrue(ok, revertMsg(ret));
        KingPredict2.Market memory m = p.get(id);
        assertEq(m.price, 7713139);
        assertTrue(m.yesWon);
        assertEq(uint8(m.state), 2);
        assertEq(kings.balanceOf(address(this)), 1_000_000 ether - 2000 ether + 3 ether);
        vm.prank(alice); p.claim(id);
        assertEq(kings.balanceOf(alice), 900 ether + 147 ether);
        assertEq(p.claimable(id, bob), 0);
    }

    function test_rejectsWrongBadOrMissingData() public {
        vm.prank(bot);
        uint256 id = p.create("Will DOGE be above $0.08 at 20:00 UTC?", 8_000_000, T19 + 1800, T20);
        vm.prank(alice); p.bet(id, true, 10 ether);
        vm.prank(bob); p.bet(id, false, 10 ether);
        bytes memory call_ = abi.encodeCall(KingPredict2.resolve, (id));

        vm.warp(T20 - 1);
        (bool ok, bytes memory ret) = callWith(address(p), call_, P20);
        assertFalse(ok); assertEq(revertMsg(ret), "Predict: too early");

        vm.warp(T20 + 60);
        (ok, ret) = callWith(address(p), call_, P19);              // real data, wrong moment
        assertFalse(ok); assertEq(revertMsg(ret), "Predict: RedStone data is not from that moment");
        (ok, ret) = callWith(address(p), call_, P20_TAMPERED);     // price changed: signature no longer matches a signer
        assertFalse(ok);
        (ok, ret) = callWith(address(p), call_, P20_TWO);          // only 2 signers
        assertFalse(ok);
        (ok, ret) = callWith(address(p), call_, P20_DUP);          // 1 signer 3 times
        assertFalse(ok);
        (ok, ret) = callWith(address(p), call_, "");               // no data at all
        assertFalse(ok);
        assertEq(uint8(p.get(id).state), 1);

        (ok, ret) = callWith(address(p), call_, P20);
        assertTrue(ok, revertMsg(ret));
        assertEq(p.get(id).price, 7713139);
        assertFalse(p.get(id).yesWon);   // 0.0771 is not above 0.08
    }

    function test_onlyOracleCreatesAndLineMustBePast() public {
        vm.prank(alice);
        (bool ok, bytes memory ret) = callWith(address(p),
            abi.encodeCall(KingPredict2.createUpDown, ("x", T19, T20 - 600, T20)), P19);
        assertFalse(ok); assertEq(revertMsg(ret), "Predict: not oracle");
        vm.warp(T19 - 100);
        vm.prank(bot);
        (ok, ret) = callWith(address(p), abi.encodeCall(KingPredict2.createUpDown, ("x", T19, T20 - 600, T20)), P19);
        assertFalse(ok); assertEq(revertMsg(ret), "Predict: start");
    }

    function test_idsContinueFromV1AndExpireCancel() public {
        vm.expectRevert(bytes("Predict: no market"));
        p.get(FIRST - 1);
        vm.startPrank(bot);
        uint256 a = p.create("A?", 1, T19 + 1800, T20);
        uint256 b = p.create("B?", 1, T19 + 1800, T20);
        vm.stopPrank();
        (uint256[] memory ids,) = p.page(0, 10);
        assertEq(ids.length, 2); assertEq(ids[0], b); assertEq(ids[1], a); assertEq(a, FIRST);
        p.cancel(a);   // owner, before close
        vm.prank(alice); p.bet(b, true, 5 ether);
        vm.warp(T19 + 1800);
        vm.expectRevert(bytes("Predict: not cancellable"));
        p.cancel(b);
        vm.warp(T20 + 1 days);
        vm.expectRevert(bytes("Predict: not expired"));
        p.expire(b);
        vm.warp(T20 + 1 days + 1);
        vm.prank(carol); p.expire(b);
        vm.prank(alice); p.claim(b);
        assertEq(kings.balanceOf(alice), 1000 ether);
    }
}

contract KingGuess2Test is RedstoneFixtures {
    KingS kings;
    KingGuess2 g;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);

    function setUp() public {
        vm.warp(uint256(DAY) * 1 days + 10 hours);
        kings = new KingS(address(this), 1_000_000 ether);
        g = new KingGuess2(address(this), kings, 10_000 ether);
        kings.transfer(address(g), 25_000 ether);
    }

    function test_settleWithRedStoneAt20() public {
        assertEq(g.today(), DAY);
        assertEq(g.targetAt(DAY), T20);
        vm.prank(alice); g.guess(7_713_000);
        vm.prank(bob); g.guess(7_720_000);
        vm.prank(carol); g.guess(7_713_000);   // same distance as alice, later
        bytes memory call_ = abi.encodeCall(KingGuess2.settle, (DAY));
        vm.warp(T20 - 1);
        (bool ok, bytes memory ret) = callWith(address(g), call_, P20);
        assertFalse(ok); assertEq(revertMsg(ret), "Guess: too early");
        vm.warp(T20 + 61);
        (ok, ret) = callWith(address(g), call_, P19);
        assertFalse(ok); assertEq(revertMsg(ret), "Guess: RedStone data is not from 20:00 UTC");
        (ok, ret) = callWith(address(g), call_, P20_TAMPERED);
        assertFalse(ok);
        vm.prank(bob);   // anyone, even a player
        (ok, ret) = callWith(address(g), call_, P20);
        assertTrue(ok, revertMsg(ret));
        KingGuess2.Day memory D = g.dayInfo(DAY);
        assertEq(D.price, 7713139);
        assertEq(D.winner, alice);
        assertEq(kings.balanceOf(alice), 10_000 ether);
        (ok, ret) = callWith(address(g), call_, P20);
        assertFalse(ok); assertEq(revertMsg(ret), "Guess: settled");
    }

    function test_tooLateAndEmptyDay() public {
        bytes memory call_ = abi.encodeCall(KingGuess2.settle, (DAY));
        vm.warp(T20 + 1 days + 1);
        (bool ok, bytes memory ret) = callWith(address(g), call_, P20);
        assertFalse(ok); assertEq(revertMsg(ret), "Guess: too late");
        vm.warp(T20 + 5);
        (ok, ret) = callWith(address(g), call_, P20);
        assertTrue(ok, revertMsg(ret));
        assertEq(g.dayInfo(DAY).price, 7713139);
        assertEq(kings.balanceOf(address(g)), 25_000 ether);
    }
}
