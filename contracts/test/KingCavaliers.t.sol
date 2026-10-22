// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KingCavaliers} from "../src/KingCavaliers.sol";
import {KingS} from "../src/KingS.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

contract KingCavaliersTest is Test {
    KingCavaliers nft;
    KingS kings;
    address owner = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 constant PRICE = 1 ether;

    function setUp() public {
        kings = new KingS(owner, 1_000_000 ether);
        nft = new KingCavaliers(owner, IERC20(address(kings)), 100, PRICE);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _mint(address who, uint256 n) internal returns (uint256 first) {
        vm.prank(who);
        first = nft.mint{value: PRICE * n}(n);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function test_mint_and_traits() public {
        uint256 first = _mint(alice, 3);
        assertEq(first, 1);
        assertEq(nft.totalMinted(), 3);
        assertEq(nft.ownerOf(3), alice);
        for (uint256 i = 1; i <= 3; i++) {
            assertTrue(nft.dna(i) != 0);
            uint256 w = nft.weight(i);
            assertGe(w, 1);
            assertLe(w, 12);
        }
        assertEq(address(nft).balance, 3 ether);
    }

    function test_mint_rules() public {
        vm.startPrank(alice);
        vm.expectRevert(KingCavaliers.BadAmount.selector);
        nft.mint{value: 0}(0);
        vm.expectRevert(KingCavaliers.BadAmount.selector);
        nft.mint{value: 6 ether}(6);
        vm.expectRevert(KingCavaliers.WrongPayment.selector);
        nft.mint{value: 1 ether}(2);
        vm.stopPrank();
        KingCavaliers small = new KingCavaliers(owner, IERC20(address(kings)), 2, PRICE);
        vm.prank(alice);
        small.mint{value: 2 ether}(2);
        vm.prank(alice);
        vm.expectRevert(KingCavaliers.SoldOut.selector);
        small.mint{value: 1 ether}(1);
    }

    function test_withdraw_to_feeTo() public {
        _mint(alice, 2);
        address treasury = address(0x7EA);
        nft.setFeeTo(treasury);
        vm.prank(bob);
        nft.withdraw();
        assertEq(treasury.balance, 2 ether);
        vm.prank(alice);
        vm.expectRevert();
        nft.setPrice(0);
    }

    function test_tokenURI_is_json_with_svg() public {
        _mint(alice, 1);
        string memory uri = nft.tokenURI(1);
        assertEq(_prefix(uri, 29), "data:application/json;base64,");
        string memory s = nft.svg(1);
        assertEq(_prefix(s, 4), "<svg");
    }

    function test_all_trait_art_renders() public {
        // force every coat/crown/accessory/eyes combination through svg()
        _mint(alice, 1);
        for (uint256 k; k < 400; k++) {
            uint256 d = uint256(keccak256(abi.encode(k))) | 1;
            vm.store(address(nft), keccak256(abi.encode(uint256(1), _dnaSlot())), bytes32(d));
            bytes memory s = bytes(nft.svg(1));
            assertGt(s.length, 500);
        }
    }

    function _dnaSlot() internal view returns (uint256 slot) {
        // find the dna mapping slot by probing
        for (slot = 0; slot < 30; slot++) {
            if (uint256(vm.load(address(nft), keccak256(abi.encode(uint256(1), slot)))) == nft.dna(1)) return slot;
        }
        revert("slot");
    }

    function test_stake_locks_and_rewards() public {
        _mint(alice, 1);
        _mint(bob, 1);
        uint256 wa = nft.weight(1);
        uint256 wb = nft.weight(2);
        vm.prank(alice);
        nft.stake(_ids(1));
        vm.prank(bob);
        nft.stake(_ids(2));
        assertEq(nft.totalWeight(), wa + wb);

        // locked while staked
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KingCavaliers.Locked.selector, 1));
        nft.transferFrom(alice, bob, 1);
        // can't stake someone else's
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KingCavaliers.NotOwner.selector, 2));
        nft.stake(_ids(2));

        kings.approve(address(nft), 1000 ether);
        nft.notifyReward(1000 ether, 1000);
        vm.warp(block.timestamp + 1000);

        uint256 ea = nft.earned(alice);
        uint256 eb = nft.earned(bob);
        assertApproxEqAbs(ea + eb, 1000 ether, 1e9);
        assertApproxEqRel(ea * wb, eb * wa, 1e12);

        vm.prank(alice);
        nft.claim();
        assertApproxEqAbs(kings.balanceOf(alice), ea, 1);

        vm.prank(alice);
        nft.unstake(_ids(1));
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
        assertEq(nft.ownerOf(1), bob);
        assertEq(nft.weightOf(alice), 0);
        assertEq(nft.totalWeight(), wb);
    }

    function test_unstake_rules() public {
        _mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KingCavaliers.NotStaked.selector, 1));
        nft.unstake(_ids(1));
        vm.prank(alice);
        nft.stake(_ids(1));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KingCavaliers.AlreadyStaked.selector, 1));
        nft.stake(_ids(1));
    }

    function test_notify_rollover() public {
        _mint(alice, 1);
        vm.prank(alice);
        nft.stake(_ids(1));
        kings.approve(address(nft), 3000 ether);
        nft.notifyReward(1000 ether, 1000);
        vm.warp(block.timestamp + 500);
        nft.notifyReward(1000 ether, 1000); // 500 left + 1000 new over 1000s
        vm.warp(block.timestamp + 1000);
        assertApproxEqAbs(nft.earned(alice), 2000 ether, 1e9);
        vm.prank(alice);
        nft.claim();
        assertApproxEqAbs(kings.balanceOf(alice), 2000 ether, 1e9);
    }

    function test_page() public {
        _mint(alice, 2);
        _mint(bob, 1);
        vm.prank(bob);
        nft.stake(_ids(3));
        (address[] memory o, uint256[] memory d, bool[] memory s) = nft.page(2, 10);
        assertEq(o.length, 2);
        assertEq(o[0], alice);
        assertEq(o[1], bob);
        assertEq(d[1], nft.dna(3));
        assertTrue(s[1]);
        (o,,) = nft.page(9, 5);
        assertEq(o.length, 0);
    }

    function _prefix(string memory s, uint256 n) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory r = new bytes(n);
        for (uint256 i; i < n; i++) r[i] = b[i];
        return string(r);
    }
}
