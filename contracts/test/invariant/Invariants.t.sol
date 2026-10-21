// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KingS} from "../../src/KingS.sol";
import {WDOGE} from "../../src/WDOGE.sol";
import {KingFactory} from "../../src/KingFactory.sol";
import {KingRouter} from "../../src/KingRouter.sol";
import {KingPair} from "../../src/KingPair.sol";
import {KingLaunch} from "../../src/KingLaunch.sol";
import {MemeToken} from "../../src/MemeToken.sol";
import {KingLimit} from "../../src/KingLimit.sol";
import {KingFarm} from "../../src/KingFarm.sol";
import {KingVote, IVoteFarm} from "../../src/KingVote.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Random buys and sells on two launchpad curves by three traders.
contract LaunchHandler is Test {
    KingLaunch public lp; address[] public toks; address[] actors;
    constructor(KingLaunch _lp, address[] memory _toks){ lp = _lp; toks = _toks; actors.push(address(0xA1)); actors.push(address(0xA2)); actors.push(address(0xA3)); for (uint i; i < 3; i++) vm.deal(actors[i], 1e24); }
    function buy(uint256 a, uint256 t, uint256 v) external {
        address u = actors[a % 3]; address tok = toks[t % toks.length];
        if (lp.info(tok).graduated) return;
        v = bound(v, 1e12, 3 ether);
        vm.prank(u); try lp.buy{value: v}(tok, 0) {} catch {}
    }
    function sell(uint256 a, uint256 t, uint256 frac) external {
        address u = actors[a % 3]; address tok = toks[t % toks.length];
        if (lp.info(tok).graduated) return;
        uint256 bal = IERC20(tok).balanceOf(u); if (bal == 0) return;
        uint256 amt = bal * bound(frac, 1, 100) / 100;
        vm.startPrank(u); IERC20(tok).approve(address(lp), amt); try lp.sell(tok, amt, 0) {} catch {} vm.stopPrank();
    }
}

contract LaunchInvariants is Test {
    KingLaunch lp; LaunchHandler h; address[] toks; WDOGE wdoge; KingFactory factory;
    function setUp() public {
        wdoge = new WDOGE(); factory = new KingFactory(address(this), address(0));
        lp = new KingLaunch(address(factory), address(wdoge), keccak256(type(KingPair).creationCode), address(this), address(0xFEE), 5 ether, 0);
        toks.push(lp.create("A", "A", "", "", 0)); toks.push(lp.create("B", "B", "", "", 0));
        h = new LaunchHandler(lp, toks);
        targetContract(address(h));
    }
    /// the launchpad always holds exactly the DOGE it owes the curves, and the unsold tokens + LP reserve
    function invariant_solvent() public view {
        uint256 owed;
        for (uint i; i < toks.length; i++){
            KingLaunch.Launch memory L = lp.info(toks[i]);
            owed += L.realDoge;
            if (!L.graduated){
                assertEq(IERC20(toks[i]).balanceOf(address(lp)), L.tokensLeft + lp.LP_TOKENS());
                assertEq(L.vTok - L.tokensLeft, lp.CURVE() * 4 / 3 - lp.CURVE());
                assertGe(L.vDoge, L.target / 3);
            } else {
                assertEq(IERC20(toks[i]).balanceOf(address(lp)), 0);
                assertEq(L.realDoge, 0);
            }
        }
        assertEq(address(lp).balance, owed);
    }
}

/// Random limit orders, cancels and fills against a KingS/DOGE pool.
contract LimitHandler is Test {
    KingLimit public lim; KingRouter router; KingS kings; WDOGE wdoge; uint256[] public ids;
    constructor(KingLimit _l, KingRouter _r, KingS _k, WDOGE _w){ lim = _l; router = _r; kings = _k; wdoge = _w; vm.deal(address(this), 1e24); }
    function placeDoge(uint256 v, uint256 m) external {
        v = bound(v, 1e12, 5 ether); m = bound(m, 1, 1e24);
        ids.push(lim.placeNative{value: v}(address(kings), m, uint64(block.timestamp + 1 days)));
    }
    function placeKings(uint256 v, uint256 m, bool nat) external {
        v = bound(v, 1e15, 1e22); m = bound(m, 1, 1e20);
        if (kings.balanceOf(address(this)) < v) return;
        kings.approve(address(lim), v);
        ids.push(lim.place(address(kings), address(wdoge), v, m, uint64(block.timestamp + 1 days), nat));
    }
    function cancel(uint256 i) external { if (ids.length == 0) return; try lim.cancel(ids[i % ids.length]) {} catch {} }
    function fill(uint256 i) external {
        if (ids.length == 0) return;
        uint256 id = ids[i % ids.length]; KingLimit.Order memory o = lim.get(id);
        address[] memory p = new address[](2); p[0] = o.tokenIn; p[1] = o.tokenOut;
        try lim.fill(id, p) {} catch {}
    }
    function warp(uint256 s) external { vm.warp(block.timestamp + bound(s, 1, 2 days)); }
    receive() external payable {}
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4){ return this.onERC1155Received.selector; }
}

contract LimitInvariants is Test {
    KingLimit lim; LimitHandler h; KingS kings; WDOGE wdoge;
    function setUp() public {
        wdoge = new WDOGE(); KingFactory f = new KingFactory(address(this), address(0)); KingRouter r = new KingRouter(address(f), address(wdoge));
        kings = new KingS(address(this), 1e27); vm.deal(address(this), 1e24);
        kings.approve(address(r), type(uint256).max);
        r.addLiquidityETH{value: 1000 ether}(address(kings), 1e25, 0, 0, address(this), block.timestamp);
        lim = new KingLimit(address(r), address(wdoge));
        h = new LimitHandler(lim, r, kings, wdoge);
        kings.transfer(address(h), 1e25);
        targetContract(address(h));
    }
    /// every open order is fully backed by tokens held in the contract
    function invariant_backed() public view {
        uint256 n = lim.count(); uint256 needK; uint256 needW;
        for (uint i; i < n; i++){ KingLimit.Order memory o = lim.get(i); if (o.status != KingLimit.Status.Open) continue;
            if (o.tokenIn == address(kings)) needK += o.amountIn; else needW += o.amountIn; }
        assertGe(kings.balanceOf(address(lim)), needK);
        assertGe(wdoge.balanceOf(address(lim)), needW);
        assertEq(address(lim).balance, 0);
    }
}

/// Random locks, unlocks and votes.
contract VoteHandler is Test {
    KingVote public kv; KingS kings; address[] actors;
    constructor(KingVote _kv, KingS _k){ kv = _kv; kings = _k; actors.push(address(0xB1)); actors.push(address(0xB2)); actors.push(address(0xB3)); }
    function lock(uint256 a, uint256 amt) external { address u = actors[a % 3]; amt = bound(amt, 1, 1e24); vm.startPrank(u); kings.approve(address(kv), amt); try kv.lock(amt) {} catch {} vm.stopPrank(); }
    function unlock(uint256 a, uint256 amt) external { address u = actors[a % 3]; uint256 l = kv.locked(u); if (l == 0) return; amt = bound(amt, 1, l); vm.prank(u); kv.unlock(amt); }
    function vote(uint256 a, uint256 p0, uint256 w) external {
        address u = actors[a % 3]; uint256[] memory p = new uint256[](2); uint256[] memory b = new uint256[](2);
        p[0] = p0 % 3; p[1] = (p0 + 1) % 3; b[0] = bound(w, 0, 10_000); b[1] = 10_000 - b[0];
        vm.prank(u); try kv.vote(p, b) {} catch {}
    }
    function applyV(uint256 s) external { vm.warp(block.timestamp + bound(s, 1, 8 days)); try kv.applyVotes() {} catch {} }
    function give(address[] memory to, uint256 amt) external pure { to; amt; }
}

contract MockLP2 { function balanceOf(address) external pure returns (uint256){ return 0; } }

contract VoteInvariants is Test {
    KingVote kv; VoteHandler h; KingS kings; KingFarm farm;
    function setUp() public {
        kings = new KingS(address(this), 1e27);
        farm = new KingFarm(IERC20(address(kings)), address(this));
        for (uint i; i < 3; i++) farm.add(10, IERC20(address(new MockLP2())));
        kv = new KingVote(IERC20(address(kings)), IVoteFarm(address(farm)), address(this), 10);
        farm.transferOwnership(address(kv));
        h = new VoteHandler(kv, kings);
        kings.transfer(address(0xB1), 1e25); kings.transfer(address(0xB2), 1e25); kings.transfer(address(0xB3), 1e25);
        targetContract(address(h));
    }
    function invariant_votesNeverExceedLocks() public view {
        assertEq(kings.balanceOf(address(kv)), kv.totalLocked());
        assertLe(kv.totalVotes(), kv.totalLocked());
        uint256[] memory t = kv.tallies(); uint256 s;
        for (uint i; i < t.length; i++) s += t[i];
        assertEq(s, kv.totalVotes());
    }
}
