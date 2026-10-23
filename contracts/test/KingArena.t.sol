// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {KingFactory} from "../src/KingFactory.sol";
import {KingPair} from "../src/KingPair.sol";
import {KingArena} from "../src/KingArena.sol";

contract ArenaTestToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract KingArenaTest is Test {
    uint256 constant WINDOW = 10 minutes;
    uint256 constant LIQ_DOGE = 100_000 ether;
    uint256 constant LIQ_TOKEN = 1_000_000 ether;

    KingFactory factory;
    KingArena arena;
    ArenaTestToken kings;
    ArenaTestToken wdoge;
    ArenaTestToken[3] toks;
    KingPair[3] pairs;

    address owner = makeAddr("owner");
    address feeTo = makeAddr("feeTo");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address keeper = makeAddr("keeper");
    address attacker = makeAddr("attacker");

    function setUp() public {
        vm.warp(1_750_000_000);
        vm.roll(1_000);

        kings = new ArenaTestToken("KingS", "KingS");
        wdoge = new ArenaTestToken("Wrapped DOGE", "WDOGE");
        factory = new KingFactory(address(this), address(0));
        toks[0] = new ArenaTestToken("Alpha", "AAA");
        toks[1] = new ArenaTestToken("Bravo", "BBB");
        toks[2] = new ArenaTestToken("Charlie", "CCC");

        address[] memory list = new address[](3);
        for (uint256 i; i < 3; ++i) {
            pairs[i] = KingPair(factory.createPair(address(toks[i]), address(wdoge)));
            toks[i].mint(address(pairs[i]), LIQ_TOKEN);
            wdoge.mint(address(pairs[i]), LIQ_DOGE);
            pairs[i].mint(address(this));
            list[i] = address(toks[i]);
        }

        arena = new KingArena(owner, address(kings), address(wdoge), address(factory), feeTo);
        vm.prank(owner);
        arena.setTokens(list);

        kings.mint(owner, 1_000 ether);
        vm.startPrank(owner);
        kings.approve(address(arena), type(uint256).max);
        arena.fundTips(1_000 ether);
        vm.stopPrank();

        address[4] memory users = [alice, bob, carol, attacker];
        for (uint256 i; i < users.length; ++i) {
            kings.mint(users[i], 100_000 ether);
            vm.prank(users[i]);
            kings.approve(address(arena), type(uint256).max);
        }

        // Move past the block that seeded the pools, so they read as untouched.
        _step(60);
    }

    // ------------------------------------------------------------------ helpers

    function _step(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + 1);
    }

    function _pokeN(uint256 n, uint256 dt) internal {
        for (uint256 i; i < n; ++i) {
            _step(dt);
            arena.poke();
        }
    }

    function _openRound() internal returns (uint256) {
        arena.poke();
        return arena.currentId();
    }

    function _stake(address user, uint256 idx, uint256 amount) internal {
        vm.prank(user);
        arena.stake(idx, amount);
    }

    /// Jumps into the end window of round `id` and records `n` samples a minute apart.
    function _endWindow(uint256 id, uint256 n) internal {
        KingArena.Round memory r = arena.getRound(id);
        vm.warp(uint256(r.end) - WINDOW + 5);
        vm.roll(block.number + 1);
        arena.poke();
        _pokeN(n - 1, 60);
    }

    function _settleAt(uint256 id) internal returns (uint256) {
        KingArena.Round memory r = arena.getRound(id);
        vm.warp(r.end);
        vm.roll(block.number + 1);
        vm.prank(keeper);
        return arena.settle();
    }

    /// Buys token `i` with `dogeIn` WDOGE (its DOGE price goes up). Tokens go to this contract.
    function _buy(uint256 i, uint256 dogeIn) internal returns (uint256 out) {
        KingPair p = pairs[i];
        (uint112 r0, uint112 r1,) = p.getReserves();
        bool w0 = p.token0() == address(wdoge);
        (uint256 rIn, uint256 rOut) = w0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        out = dogeIn * 997 * rOut / (rIn * 1000 + dogeIn * 997);
        wdoge.mint(address(p), dogeIn);
        if (w0) p.swap(0, out, address(this));
        else p.swap(out, 0, address(this));
    }

    /// Sells `tokIn` of token `i` (held by this contract) for WDOGE (its DOGE price goes down).
    function _sell(uint256 i, uint256 tokIn) internal returns (uint256 out) {
        KingPair p = pairs[i];
        (uint112 r0, uint112 r1,) = p.getReserves();
        bool w0 = p.token0() == address(wdoge);
        (uint256 rIn, uint256 rOut) = w0 ? (uint256(r1), uint256(r0)) : (uint256(r0), uint256(r1));
        out = tokIn * 997 * rOut / (rIn * 1000 + tokIn * 997);
        toks[i].transfer(address(p), tokIn);
        if (w0) p.swap(out, 0, address(this));
        else p.swap(0, out, address(this));
    }

    /// One round where Alice backs AAA, Bob backs BBB, and AAA wins.
    function _playRoundAWins() internal returns (uint256 id) {
        id = _openRound();
        _step(60);
        _stake(alice, 0, 1_000 ether);
        _step(60);
        _stake(bob, 1, 1_000 ether);
        _pokeN(3, 60);
        _step(20 minutes);
        _buy(0, 5_000 ether);
        _endWindow(id, 4);
        _settleAt(id);
    }

    // ------------------------------------------------------------------ tests

    function test_normalRound() public {
        uint256 id = _openRound(); // start sample 1
        assertEq(id, 1);
        _step(60);
        _stake(alice, 0, 1_000 ether); // 2
        _step(60);
        _stake(bob, 1, 3_000 ether); // 3
        _step(60);
        _stake(carol, 0, 2_000 ether); // 4
        _pokeN(2, 60); // 5, 6

        assertEq(arena.myStakes(id, alice)[0], 1_000 ether);
        (uint256[] memory pots,,,,) = arena.board(id);
        assertEq(pots[0], 3_000 ether);
        assertEq(pots[1], 3_000 ether);

        // Mid-round, AAA really rises against DOGE (about 10%).
        _step(20 minutes);
        _buy(0, 5_000 ether);
        _step(60);
        arena.poke(); // outside both windows, not recorded

        _endWindow(id, 5);

        // Staking is closed during the end window.
        vm.expectRevert(bytes("KingArena: STAKING_CLOSED"));
        vm.prank(alice);
        arena.stake(0, 1_000 ether);

        (, uint256[] memory sAvg, uint256[] memory eAvg, uint32[] memory sCnt, uint32[] memory eCnt) = arena.board(id);
        assertEq(sCnt[0], 6);
        assertEq(eCnt[0], 5);
        assertGt(eAvg[0], sAvg[0]);
        assertEq(eAvg[1], sAvg[1]);
        assertEq(eAvg[2], sAvg[2]);

        uint256 keeperBefore = kings.balanceOf(keeper);
        assertEq(_settleAt(id), id);
        assertEq(kings.balanceOf(keeper) - keeperBefore, 10 ether, "settle tip");
        assertEq(arena.tipReserve(), 990 ether);

        KingArena.Round memory r = arena.getRound(id);
        assertTrue(r.settled);
        assertEq(r.winnerMask, 1);
        assertEq(r.staked, 6_000 ether);
        assertEq(r.winnerStake, 3_000 ether);
        assertEq(r.payout, 5_880 ether);
        assertEq(kings.balanceOf(feeTo), 120 ether, "2% fee");

        assertEq(arena.claimable(id, alice), 1_960 ether);
        assertEq(arena.claimable(id, carol), 3_920 ether);
        assertEq(arena.claimable(id, bob), 0);

        uint256 a0 = kings.balanceOf(alice);
        vm.prank(alice);
        arena.claim(id);
        assertEq(kings.balanceOf(alice) - a0, 1_960 ether);
        vm.prank(carol);
        arena.claim(id);

        vm.expectRevert(bytes("KingArena: NOTHING_TO_CLAIM"));
        vm.prank(bob);
        arena.claim(id);

        // The settle call opened round 2.
        assertEq(arena.currentId(), 2);
        (uint256[] memory ids,) = arena.claimableRounds(alice, 0, 10);
        assertEq(ids.length, 0);
    }

    function test_rolloverWhenNobodyBackedWinner() public {
        uint256 id1 = _openRound();
        _step(60);
        _stake(alice, 1, 2_000 ether); // backs BBB
        _pokeN(3, 60);
        _step(20 minutes);
        _buy(0, 5_000 ether); // AAA wins
        _endWindow(id1, 4);

        uint256 feeBefore = kings.balanceOf(feeTo);
        _settleAt(id1);

        KingArena.Round memory r1 = arena.getRound(id1);
        assertEq(r1.winnerMask, 1);
        assertEq(r1.winnerStake, 0);
        assertEq(r1.payout, 0);
        assertEq(kings.balanceOf(feeTo), feeBefore, "no fee on rollover");
        assertEq(arena.claimable(id1, alice), 0);

        uint256 id2 = arena.currentId();
        assertEq(id2, id1 + 1);
        assertEq(arena.getRound(id2).rollover, 2_000 ether);
        (,,,,uint256 pot,,,) = _cur();
        assertEq(pot, 2_000 ether);

        // Round 2: the settle poke was start sample 1. CCC wins this time.
        _step(60);
        _stake(bob, 2, 1_000 ether);
        _step(60);
        _stake(carol, 0, 1_000 ether);
        _pokeN(2, 60);
        _step(20 minutes);
        _buy(2, 5_000 ether);
        _endWindow(id2, 4);
        _settleAt(id2);

        KingArena.Round memory r2 = arena.getRound(id2);
        assertEq(r2.winnerMask, 4);
        // pot = 2,000 staked + 2,000 rolled over; 2% fee = 80
        assertEq(kings.balanceOf(feeTo), feeBefore + 80 ether);
        assertEq(arena.claimable(id2, bob), 3_920 ether);
        assertEq(arena.claimable(id2, carol), 0);
    }

    function test_tooFewSamplesCannotWin() public {
        uint256 id = _openRound(); // start sample 1
        _step(60);
        _stake(alice, 0, 1_000 ether); // start sample 2, and no more
        _step(20 minutes);
        _buy(0, 5_000 ether);
        _endWindow(id, 5);
        _settleAt(id);

        KingArena.Round memory r = arena.getRound(id);
        assertEq(r.winnerMask, 0);
        assertEq(r.winnerStake, 0);
        assertEq(arena.getRound(id + 1).rollover, 1_000 ether);
        assertEq(arena.claimable(id, alice), 0);
    }

    function test_tieSplitsPotBetweenTiedTokens() public {
        uint256 id = _openRound();
        _step(60);
        _stake(alice, 0, 1_000 ether);
        _step(60);
        _stake(bob, 1, 3_000 ether);
        _step(60);
        _stake(carol, 2, 2_000 ether);
        _pokeN(2, 60);

        // CCC falls; AAA and BBB stay flat, so both have exactly the same (best) ratio.
        _step(20 minutes);
        toks[2].mint(address(this), 50_000 ether);
        _sell(2, 50_000 ether);
        _endWindow(id, 4);
        _settleAt(id);

        KingArena.Round memory r = arena.getRound(id);
        assertEq(r.winnerMask, 3);
        assertEq(r.winnerStake, 4_000 ether);
        assertEq(r.payout, 5_880 ether);
        assertEq(arena.claimable(id, alice), 1_470 ether);
        assertEq(arena.claimable(id, bob), 4_410 ether);
        assertEq(arena.claimable(id, carol), 0);
    }

    function test_claimTwiceReverts() public {
        uint256 id = _playRoundAWins();
        assertGt(arena.claimable(id, alice), 0);
        vm.prank(alice);
        arena.claim(id);
        assertEq(arena.claimable(id, alice), 0);

        vm.expectRevert(bytes("KingArena: ALREADY_CLAIMED"));
        vm.prank(alice);
        arena.claim(id);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.expectRevert(bytes("KingArena: NOTHING_TO_CLAIM"));
        vm.prank(alice);
        arena.claimMany(ids);
    }

    function test_settleEarlyReverts() public {
        vm.expectRevert(bytes("KingArena: TOO_EARLY"));
        arena.settle();

        uint256 id = _openRound();
        _step(60);
        _stake(alice, 0, 1_000 ether);

        vm.expectRevert(bytes("KingArena: TOO_EARLY"));
        arena.settle();

        vm.expectRevert(bytes("KingArena: NOT_SETTLED"));
        vm.prank(alice);
        arena.claim(id);

        KingArena.Round memory r = arena.getRound(id);
        vm.warp(uint256(r.end) - 1);
        vm.roll(block.number + 1);
        vm.expectRevert(bytes("KingArena: TOO_EARLY"));
        arena.settle();

        vm.warp(r.end);
        vm.roll(block.number + 1);
        arena.settle();
        assertTrue(arena.getRound(id).settled);

        // Round 2 has only just started.
        vm.expectRevert(bytes("KingArena: TOO_EARLY"));
        arena.settle();
    }

    function test_twapManipulationAttemptFails() public {
        uint256 id = _openRound();
        _step(60);
        _stake(alice, 0, 1_000 ether); // honest bet on AAA
        _step(60);
        _stake(attacker, 2, 5_000 ether); // attacker bets on CCC
        _pokeN(3, 60);

        _step(20 minutes);
        _buy(0, 5_000 ether); // AAA genuinely rises ~10%
        _endWindow(id, 4);

        (, uint256[] memory sAvg0,,, uint32[] memory eCnt0) = arena.board(id);

        // Attacker's block: pump CCC about 9x, poke, dump it back. All inside one block.
        _step(30);
        uint256 got = _buy(2, 200_000 ether);
        assertGt(arena.spotPrices(id)[2], sAvg0[2] * 5, "spot really is skewed");
        arena.poke();
        arena.poke(); // a second poke in the same block does nothing
        _sell(2, got);

        (, uint256[] memory sAvg, uint256[] memory eAvg,, uint32[] memory eCnt) = arena.board(id);
        assertEq(eCnt[2], eCnt0[2] + 1, "one sample per block");
        assertEq(eAvg[2], sAvg[2], "sample used the last clean price, not the skewed spot");

        _settleAt(id);
        assertEq(arena.getRound(id).winnerMask, 1);
        assertEq(arena.claimable(id, attacker), 0);
        assertGt(arena.claimable(id, alice), 0);
    }

    function test_configChangesApplyFromNextRound() public {
        uint256 id = _openRound();
        address[] memory two = new address[](2);
        two[0] = address(toks[0]);
        two[1] = address(toks[1]);

        vm.startPrank(owner);
        arena.setTokens(two);
        arena.setFeeBps(500);
        arena.setRoundDuration(2 hours);
        vm.expectRevert(bytes("KingArena: FEE_TOO_HIGH"));
        arena.setFeeBps(501);
        vm.expectRevert(bytes("KingArena: KINGS_LOCKED"));
        arena.rescueToken(address(kings), owner, 1);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        arena.setFeeBps(0);

        KingArena.Round memory r = arena.getRound(id);
        assertEq(r.feeBps, 200);
        assertEq(r.end - r.start, 1 hours);
        (address[] memory t1,) = arena.roundTokens(id);
        assertEq(t1.length, 3);

        vm.warp(r.end);
        vm.roll(block.number + 1);
        arena.poke();
        KingArena.Round memory r2 = arena.getRound(id + 1);
        assertEq(r2.start, r.end);
        assertEq(r2.feeBps, 500);
        assertEq(r2.end - r2.start, 2 hours);
        (address[] memory t2,) = arena.roundTokens(id + 1);
        assertEq(t2.length, 2);
    }

    function _cur()
        internal
        view
        returns (uint256 id, uint64 start, uint64 end, uint64 stakingEndsAt, uint256 pot, uint16 feeBps, bool live, uint256 left)
    {
        (id, start, end, stakingEndsAt, left, pot, feeBps, live) = arena.currentRound();
    }
}
