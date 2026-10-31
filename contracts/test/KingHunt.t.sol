// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KingHunt} from "../src/KingHunt.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract K is ERC20 { constructor() ERC20("KingS", "KINGS") { _mint(msg.sender, 1e30); } }

contract KingHuntTest is Test {
    KingHunt h;
    K k;
    address owner = address(this);
    address[4] p = [address(0xA1), address(0xA2), address(0xA3), address(0xA4)];
    string[3] ans = ["rpup", "earlypup", "49"];

    function key(uint256 id, uint8 i, string memory a) internal pure returns (bytes32) { return keccak256(abi.encodePacked(id, i, a)); }

    function setUp() public {
        vm.warp(1_800_000_000);
        k = new K();
        h = new KingHunt(owner, IERC20(address(k)));
        string[] memory clues = new string[](3);
        bytes32[] memory keys = new bytes32[](3);
        for (uint8 i; i < 3; i++) { clues[i] = "riddle"; keys[i] = key(0, i, ans[i]); }
        k.approve(address(h), 100_000 ether);
        h.create("Hunt #1", uint64(block.timestamp), uint64(block.timestamp + 7 days), clues, keys, 100_000 ether);
    }

    function solve(address who, uint8 i, string memory a) internal {
        bytes32 kk = key(0, i, a);
        vm.prank(who);
        h.commit(keccak256(abi.encode(who, uint256(0), i, kk)));
        vm.roll(block.number + 1);
        vm.prank(who);
        h.reveal(0, i, kk);
    }

    function testFullFlowAndPrizes() public {
        for (uint256 w; w < 4; w++) for (uint8 i; i < 3; i++) solve(p[w], i, ans[i]);
        assertEq(k.balanceOf(p[0]), 50_000 ether);
        assertEq(k.balanceOf(p[1]), 30_000 ether);
        assertEq(k.balanceOf(p[2]), 20_000 ether);
        assertEq(k.balanceOf(p[3]), 0);
        (KingHunt.Hunt memory hh,,, uint32[] memory solvers, address[3] memory top) = h.get(0);
        assertEq(hh.finishers, 4);
        assertEq(solvers[0], 4);
        assertEq(top[0], p[0]);
        assertEq(top[2], p[2]);
    }

    function testRevealNeedsEarlierCommit() public {
        bytes32 kk = key(0, 0, "rpup");
        vm.prank(p[0]);
        vm.expectRevert("Hunt: commit first");
        h.reveal(0, 0, kk);
        vm.prank(p[0]);
        h.commit(keccak256(abi.encode(p[0], uint256(0), uint8(0), kk)));
        vm.prank(p[0]);
        vm.expectRevert("Hunt: commit first");   // same block
        h.reveal(0, 0, kk);
        // a copier who saw the key cannot use the victim's commit
        vm.roll(block.number + 1);
        vm.prank(p[1]);
        vm.expectRevert("Hunt: commit first");
        h.reveal(0, 0, kk);
        vm.prank(p[0]);
        h.reveal(0, 0, kk);
    }

    function testWrongAnswerAndDouble() public {
        bytes32 bad = key(0, 0, "nope");
        vm.prank(p[0]);
        h.commit(keccak256(abi.encode(p[0], uint256(0), uint8(0), bad)));
        vm.roll(block.number + 1);
        vm.prank(p[0]);
        vm.expectRevert("Hunt: wrong answer");
        h.reveal(0, 0, bad);
        solve(p[0], 0, "rpup");
        bytes32 kk = key(0, 0, "rpup");
        vm.prank(p[0]);
        vm.expectRevert("Hunt: committed");
        h.commit(keccak256(abi.encode(p[0], uint256(0), uint8(0), kk)));
    }

    function testClosedAndReclaim() public {
        solve(p[0], 0, "rpup");
        vm.warp(block.timestamp + 8 days);
        bytes32 kk = key(0, 1, "earlypup");
        vm.prank(p[0]);
        h.commit(keccak256(abi.encode(p[0], uint256(0), uint8(1), kk)));
        vm.roll(block.number + 1);
        vm.prank(p[0]);
        vm.expectRevert("Hunt: closed");
        h.reveal(0, 1, kk);
        uint256 before = k.balanceOf(owner);
        h.reclaim(0);
        assertEq(k.balanceOf(owner) - before, 100_000 ether);
        vm.expectRevert("Hunt: nothing left");
        h.reclaim(0);
    }

    function testOnlyOwnerCreates() public {
        string[] memory c = new string[](1); bytes32[] memory kk = new bytes32[](1); c[0] = "x"; kk[0] = bytes32(uint256(1));
        vm.prank(p[0]);
        vm.expectRevert();
        h.create("x", uint64(block.timestamp), uint64(block.timestamp + 1), c, kk, 0);
    }
}
