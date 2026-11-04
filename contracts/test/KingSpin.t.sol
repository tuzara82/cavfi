// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KingSpin} from "../src/KingSpin.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract KS is ERC20 { constructor() ERC20("KingS", "KINGS") { _mint(msg.sender, 1e30); } }

contract KingSpinTest is Test {
    KingSpin s;
    KS k;
    address house = address(0xB07);
    address alice = address(0xA1);
    address bob = address(0xB0B);
    bytes32[] chain;
    uint256 constant N = 3000;
    uint256 anchorRound;

    function setUp() public {
        vm.warp(1_800_000_000);
        k = new KS();
        s = new KingSpin(address(this), house, IERC20(address(k)));
        k.approve(address(s), type(uint256).max);
        s.fund(1_000_000 ether);
        chain.push(keccak256("x"));
        for (uint256 i = 1; i <= N; i++) chain.push(keccak256(abi.encodePacked(chain[i - 1])));
        vm.prank(house);
        s.setAnchor(chain[N], N);
        anchorRound = 1_800_000_000 / 30;
        vm.warp(1_800_000_000 + 30);
    }

    function seedOf(uint256 r) internal view returns (bytes32) { return chain[N - (r - anchorRound)]; }

    function testSpinOncePerDayAndPay() public {
        uint256 r = vm.getBlockTimestamp() / 30;
        vm.prank(alice); uint256 a = s.spin();
        vm.prank(bob); uint256 b = s.spin();
        vm.prank(alice);
        vm.expectRevert("Spin: one spin a day");
        s.spin();
        assertEq(s.reserved(), 2 * 50_000 ether);
        vm.warp((r + 1) * 30);
        s.reveal(seedOf(r));
        assertEq(s.reserved(), 0);
        for (uint256 i; i < 2; i++) {
            uint256 id = i == 0 ? a : b;
            KingSpin.Spin memory x = s.get(id);
            uint8 seg = uint8(uint256(keccak256(abi.encodePacked(seedOf(r), id))) % 20);
            assertEq(x.segment, seg);
            assertEq(x.prize, s.segmentUnits(seg) * 100 ether);
            assertEq(k.balanceOf(i == 0 ? alice : bob), x.prize);
        }
        // next UTC day: spin again
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 5);
        vm.prank(alice);
        s.spin();
    }

    function testAverage() public view {
        uint256 sum;
        for (uint256 i; i < 20; i++) sum += s.segmentUnits(i);
        assertEq(sum, 890);   // 44.5 units a spin on average
    }

    function testFundEmptyAndTimeout() public {
        s.withdraw(s.free() - 60_000 ether, address(this));
        vm.prank(alice); uint256 a = s.spin();
        vm.prank(bob);
        vm.expectRevert("Spin: prize fund empty");
        s.spin();
        vm.warp(vm.getBlockTimestamp() + 30 + 1 hours + 1);
        s.claimTimeout(a);
        assertEq(k.balanceOf(alice), 50_000 ether);
    }

    function testOutOfOrderReveal() public {
        uint256 r = vm.getBlockTimestamp() / 30;
        vm.prank(alice); s.spin();
        vm.warp((r + 2) * 30 + 1);
        vm.prank(bob); s.spin();
        vm.warp((r + 3) * 30 + 1);
        vm.expectRevert("Spin: bad seed");
        s.reveal(seedOf(r + 2));
        s.reveal(seedOf(r));
        s.reveal(seedOf(r + 2));
        assertEq(s.reserved(), 0);
    }
}
