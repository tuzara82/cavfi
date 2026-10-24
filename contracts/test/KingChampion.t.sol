// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {KingArenaTest} from "./KingArena.t.sol";
import {KingChampion} from "../src/KingChampion.sol";

/// Reuses the Arena test setup (pools, tokens, players) to play real rounds.
contract KingChampionTest is KingArenaTest {
    KingChampion champ;

    function _deployChampion() internal {
        if (address(champ) == address(0)) champ = new KingChampion(address(arena));
    }

    function test_winnerClaimsOnce_loserCannot() public {
        _deployChampion();
        uint256 id = _playRoundAWins(); // alice backed AAA (won), bob backed BBB (lost)
        assertTrue(champ.wonIn(id, alice));
        assertFalse(champ.wonIn(id, bob));

        vm.prank(alice);
        champ.claim(id);
        assertEq(champ.balanceOf(alice, 1), 1);
        assertEq(champ.wonRound(alice), id);

        vm.prank(alice);
        vm.expectRevert(bytes("Champion: already yours"));
        champ.claim(id);

        vm.prank(bob);
        vm.expectRevert(bytes("Champion: no win in that round"));
        champ.claim(id);

        // works whether or not the winnings were claimed from the Arena already
        vm.prank(alice);
        arena.claim(id);
        assertTrue(champ.wonIn(id, alice));
    }

    function test_unsettledOrRolledRoundGivesNothing() public {
        _deployChampion();
        uint256 id = _openRound();
        _step(60);
        _stake(alice, 0, 1_000 ether);
        assertFalse(champ.wonIn(id, alice)); // not settled yet
        vm.prank(alice);
        vm.expectRevert(bytes("Champion: no win in that round"));
        champ.claim(id);
        assertFalse(champ.wonIn(999, alice)); // round that never existed
    }

    function test_soulbound() public {
        _deployChampion();
        uint256 id = _playRoundAWins();
        vm.prank(alice);
        champ.claim(id);
        vm.prank(alice);
        vm.expectRevert(bytes("Champion: soulbound"));
        champ.safeTransferFrom(alice, bob, 1, 1, "");
        vm.expectRevert(bytes("Champion: soulbound"));
        champ.setApprovalForAll(bob, true);
        assertGt(bytes(champ.uri(1)).length, 100);
    }
}
