// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KingRaid} from "../src/KingRaid.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract KR is ERC20 { constructor() ERC20("KingS", "KINGS") { _mint(msg.sender, 1e30); } }

contract KingRaidTest is Test {
    KingRaid r;
    KR k;
    address bot = address(0xB07);
    address a = address(0xA1);
    address b = address(0xB0B);

    function setUp() public {
        vm.warp(1_800_000_000);
        k = new KR();
        r = new KingRaid(address(this), IERC20(address(k)));
        r.setAttester(bot, true);
        k.approve(address(r), type(uint256).max);
        r.create("The Fat Cat", uint64(vm.getBlockTimestamp()), uint64(vm.getBlockTimestamp() + 7 days), 1000, 100_000 ether);
    }

    function hits(address[] memory w, uint256[] memory d) internal {
        vm.prank(bot);
        r.hit(0, w, d);
    }

    function testDefeatAndProRataClaim() public {
        address[] memory w = new address[](2); w[0] = a; w[1] = b;
        uint256[] memory d = new uint256[](2); d[0] = 300; d[1] = 100;
        hits(w, d);
        assertEq(r.get(0).hp, 600);
        assertEq(r.claimable(0, a), 0);   // not defeated yet
        d[0] = 500; d[1] = 900;           // a takes it to 100 HP, b lands the final blow with only 100 counted
        hits(w, d);
        KingRaid.Raid memory x = r.get(0);
        assertEq(x.hp, 0);
        assertEq(x.finalBlow, b);
        assertEq(x.totalDamage, 1000);
        assertEq(r.damageOf(0, a), 800);
        assertEq(r.damageOf(0, b), 200);
        vm.prank(a); r.claim(0);
        vm.prank(b); r.claim(0);
        assertEq(k.balanceOf(a), 80_000 ether);
        assertEq(k.balanceOf(b), 20_000 ether);
        vm.prank(a);
        vm.expectRevert("Raid: nothing to claim");
        r.claim(0);
        // a defeated boss takes no more hits
        vm.prank(bot);
        vm.expectRevert("Raid: not running");
        r.hit(0, w, d);
    }

    function testOnlyAttester() public {
        address[] memory w = new address[](1); w[0] = a;
        uint256[] memory d = new uint256[](1); d[0] = 1;
        vm.expectRevert("Raid: not attester");
        r.hit(0, w, d);
    }

    function testReclaimWhenBossSurvives() public {
        address[] memory w = new address[](1); w[0] = a;
        uint256[] memory d = new uint256[](1); d[0] = 10;
        hits(w, d);
        vm.expectRevert("Raid: running or won");
        r.reclaim(0);
        vm.warp(vm.getBlockTimestamp() + 8 days);
        uint256 before = k.balanceOf(address(this));
        r.reclaim(0);
        assertEq(k.balanceOf(address(this)) - before, 100_000 ether);
        assertEq(r.claimable(0, a), 0);
    }

    function testPage() public {
        address[] memory w = new address[](2); w[0] = a; w[1] = b;
        uint256[] memory d = new uint256[](2); d[0] = 5; d[1] = 7;
        hits(w, d);
        hits(w, d);
        (address[] memory who, uint256[] memory dmg) = r.page(0, 0, 10);
        assertEq(who.length, 2);
        assertEq(dmg[0], 10);
        assertEq(dmg[1], 14);
        assertEq(r.playerCount(0), 2);
    }
}
