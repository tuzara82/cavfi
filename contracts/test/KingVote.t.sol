// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KingS} from "../src/KingS.sol";
import {KingFarm} from "../src/KingFarm.sol";
import {KingVote, IVoteFarm} from "../src/KingVote.sol";

contract MockLP is ERC20 { constructor() ERC20("LP", "LP") { _mint(msg.sender, 1e30); } }

contract KingVoteTest is Test {
    KingS kings;
    KingFarm farm;
    KingVote kv;
    MockLP lp0; MockLP lp1; MockLP lp2;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        kings = new KingS(address(this), 1_000_000_000 ether);
        farm = new KingFarm(IERC20(address(kings)), address(this));
        lp0 = new MockLP(); lp1 = new MockLP(); lp2 = new MockLP();
        farm.add(40, IERC20(address(lp0)));
        farm.add(30, IERC20(address(lp1)));
        kv = new KingVote(IERC20(address(kings)), IVoteFarm(address(farm)), address(this), 10);
        farm.transferOwnership(address(kv));
        kv.addFarmPool(IERC20(address(lp2)));
        kings.transfer(alice, 1000 ether);
        kings.transfer(bob, 3000 ether);
        vm.prank(alice); kings.approve(address(kv), type(uint256).max);
        vm.prank(bob); kings.approve(address(kv), type(uint256).max);
    }

    function _one(uint256 pid) internal pure returns (uint256[] memory p, uint256[] memory b) { p = new uint256[](1); b = new uint256[](1); p[0] = pid; b[0] = 10_000; }

    function _alloc(uint256 pid) internal view returns (uint256 a) { (, a, , , ) = farm.poolInfo(pid); }

    function test_votesSetWeights() public {
        vm.startPrank(alice); kv.lock(1000 ether); (uint256[] memory p, uint256[] memory b) = _one(2); kv.vote(p, b); vm.stopPrank();
        vm.startPrank(bob); kv.lock(3000 ether);
        uint256[] memory p2 = new uint256[](2); uint256[] memory b2 = new uint256[](2);
        p2[0] = 0; p2[1] = 1; b2[0] = 5000; b2[1] = 5000; kv.vote(p2, b2); vm.stopPrank();
        kv.applyVotes();
        assertEq(_alloc(0), 10 + 375); // bob 1500 of 4000 votes
        assertEq(_alloc(1), 10 + 375);
        assertEq(_alloc(2), 10 + 250); // alice 1000 of 4000
        vm.expectRevert(bytes("KingVote: TOO_SOON"));
        kv.applyVotes();
        vm.warp(block.timestamp + 7 days);
        kv.applyVotes();
    }

    function test_unlockRemovesVotesNoDoubleCount() public {
        vm.startPrank(alice);
        kv.lock(1000 ether);
        (uint256[] memory p, uint256[] memory b) = _one(1);
        kv.vote(p, b);
        assertEq(kv.tally(1), 1000 ether);
        kv.unlock(400 ether);
        assertEq(kv.tally(1), 600 ether);
        assertEq(kv.totalVotes(), 600 ether);
        kings.transfer(bob, 400 ether);
        vm.stopPrank();
        // bob locks the same coins: total still equals locked
        vm.startPrank(bob); kv.lock(400 ether); kv.vote(p, b); vm.stopPrank();
        assertEq(kv.totalVotes(), kv.totalLocked());
        assertEq(kings.balanceOf(address(kv)), kv.totalLocked());
    }

    function test_badVotes() public {
        vm.startPrank(alice);
        kv.lock(10 ether);
        uint256[] memory p = new uint256[](2); uint256[] memory b = new uint256[](2);
        p[0] = 0; p[1] = 0; b[0] = 5000; b[1] = 5000;
        vm.expectRevert(bytes("KingVote: DUPLICATE")); kv.vote(p, b);
        p[1] = 9;
        vm.expectRevert(bytes("KingVote: POOL")); kv.vote(p, b);
        p[1] = 1; b[1] = 4000;
        vm.expectRevert(bytes("KingVote: BPS")); kv.vote(p, b);
        // clearing is allowed
        kv.vote(new uint256[](0), new uint256[](0));
        assertEq(kv.totalVotes(), 0);
        vm.stopPrank();
    }

    function test_noVotesKeepsWeights() public {
        kv.applyVotes();
        assertEq(_alloc(0), 40);
        assertEq(_alloc(2), 10);
    }

    function test_adminCanFundButNotSetWeights() public {
        kings.approve(address(kv), 1000 ether);
        kv.fundFarm(1000 ether, 10 days);
        assertEq(kings.balanceOf(address(farm)), 1000 ether);
        assertEq(kings.balanceOf(address(kv)), 0);
        vm.prank(alice);
        vm.expectRevert();
        kv.addFarmPool(IERC20(address(lp0)));
        kv.releaseFarm(address(this));
        assertEq(farm.owner(), address(this));
    }
}
