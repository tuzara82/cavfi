// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WDOGE} from "../src/WDOGE.sol";
import {KingFactory} from "../src/KingFactory.sol";
import {KingRouter} from "../src/KingRouter.sol";
import {KingPair} from "../src/KingPair.sol";
import {KingLaunch} from "../src/KingLaunch.sol";
import {KingLimit} from "../src/KingLimit.sol";
import {KingBadges} from "../src/KingBadges.sol";

contract KingBadgesTest is Test {
    WDOGE wdoge; KingFactory factory; KingRouter router; KingLaunch lp; KingLimit lim; KingBadges bd;
    address alice = address(0xA11CE); address bob = address(0xB0B); address bot = address(0xB07);

    function setUp() public {
        wdoge = new WDOGE();
        factory = new KingFactory(address(this), address(0));
        router = new KingRouter(address(factory), address(wdoge));
        lp = new KingLaunch(address(factory), address(wdoge), keccak256(type(KingPair).creationCode), address(this), address(0xFEE), 1 ether, 0);
        lim = new KingLimit(address(router), address(wdoge));
        bd = new KingBadges(address(this), bot);
        bd.setSources(address(lp), address(lim), address(0), address(0), address(factory), address(0));
        vm.deal(alice, 100 ether); vm.deal(bob, 100 ether);
    }

    function test_launcherCreatorLiquidityPatient() public {
        vm.startPrank(alice);
        address t = lp.create("Pup", "PUP", "", "", 0);
        bd.claimLauncher(t);
        vm.expectRevert(bytes("Badges: already yours"));
        bd.claimLauncher(t);
        vm.expectRevert(bytes("Badges: your token has not graduated"));
        bd.claimCreator(t);
        lp.buy{value: 2 ether}(t, 0); // graduates
        bd.claimCreator(t);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(bytes("Badges: not your launch"));
        bd.claimLauncher(t);

        // bob adds liquidity to the graduated pool and claims Liquidity Lord
        address pair = factory.getPair(t, address(wdoge));
        address[] memory path = new address[](2); path[0] = address(wdoge); path[1] = t;
        vm.startPrank(bob);
        router.swapExactETHForTokens{value: 0.1 ether}(0, path, bob, block.timestamp);
        // limit order that fills right away -> Patient Pup
        uint256 id = lim.placeNative{value: 0.01 ether}(t, 1, uint64(block.timestamp + 1 days));
        lim.fill(id, path);
        bd.claimPatient(id);
        vm.stopPrank();
        assertEq(bd.badgesOf(alice), (1 << 1) | (1 << 2));
        assertEq(bd.badgesOf(bob), 1 << 3);
        vm.prank(alice);
        vm.expectRevert(bytes("Badges: no LP in that pool"));
        bd.claimLiquidity(pair);
    }

    function test_soulboundAndAward() public {
        address[] memory to = new address[](2); to[0] = alice; to[1] = bob;
        vm.prank(alice);
        vm.expectRevert(bytes("Badges: not minter"));
        bd.award(to, 1);
        vm.prank(bot);
        bd.award(to, 1);
        vm.prank(bot);
        bd.award(to, 1); // second time: skipped
        assertEq(bd.holders(1), 2);
        vm.prank(bot);
        vm.expectRevert(bytes("Badges: claim this one yourself"));
        bd.award(to, 2);
        vm.prank(alice);
        vm.expectRevert(bytes("Badges: soulbound"));
        bd.safeTransferFrom(alice, bob, 1, 1, "");
        vm.expectRevert(bytes("Badges: soulbound"));
        bd.setApprovalForAll(bob, true);
    }

    function test_uriIsJson() public view {
        string memory u = bd.uri(3);
        assertGt(bytes(u).length, 200);
        assertEq(bytes(bd.svg(8))[1], bytes1("s"));
    }
}
