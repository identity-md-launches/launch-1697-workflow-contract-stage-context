// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GraveyardBase} from "./GraveyardBase.sol";
import {Graveyard} from "../src/Graveyard.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract GraveyardTest is GraveyardBase {
    event WakeTokenSet(address indexed token);
    event Consecrated(address indexed token);
    event Funded(address indexed funder, uint256 amount);
    event Buried(address indexed token, address indexed mourner, uint256 amount, uint256 reward);
    event Epitaph(address indexed token, address indexed mourner, string text);
    event Flowers(address indexed token, address indexed mourner, uint256 amount);

    function test_ExplicitOwnerAndInvalidOwner() public {
        assertEq(graveyard.owner(), owner);
        vm.expectRevert(Graveyard.InvalidAddress.selector);
        new Graveyard(address(0));
        vm.expectRevert(Graveyard.InvalidAddress.selector);
        new Graveyard(DEAD);
    }

    function test_UnconfiguredStateAndOwnerSetsTokenOnce() public {
        Graveyard fresh = new Graveyard(owner);
        assertEq(address(fresh.wakeToken()), address(0));
        assertFalse(fresh.canBury(alice, address(deadToken)));
        vm.expectRevert(Graveyard.WakeNotConfigured.selector);
        fresh.nextReward();
        vm.expectRevert(Graveyard.WakeNotConfigured.selector);
        fresh.bury(address(deadToken));
        vm.expectRevert(Graveyard.WakeNotConfigured.selector);
        fresh.buryMany(_single(address(deadToken)));
        vm.expectRevert(Graveyard.WakeNotConfigured.selector);
        fresh.layFlowers(address(deadToken), 1);
        vm.startPrank(owner);
        vm.expectRevert(Graveyard.WakeNotConfigured.selector);
        fresh.fund(1);
        vm.expectRevert(Graveyard.WakeNotConfigured.selector);
        fresh.consecrate(_single(address(deadToken)));
        vm.expectEmit(true, false, false, true, address(fresh));
        emit WakeTokenSet(address(wake));
        fresh.setWakeToken(address(wake));
        assertEq(address(fresh.wakeToken()), address(wake));
        vm.expectRevert(Graveyard.WakeAlreadyConfigured.selector);
        fresh.setWakeToken(address(otherToken));
        vm.stopPrank();
    }

    function test_SetTokenRejectsInvalidAddressesAndUnauthorizedCaller() public {
        Graveyard fresh = new Graveyard(owner);
        vm.expectRevert(Graveyard.Unauthorized.selector);
        fresh.setWakeToken(address(wake));
        address[4] memory invalid = [address(0), DEAD, outsider, address(fresh)];
        vm.startPrank(owner);
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(Graveyard.InvalidToken.selector, invalid[i]));
            fresh.setWakeToken(invalid[i]);
        }
        vm.stopPrank();
        assertEq(address(fresh.wakeToken()), address(0));
    }

    function test_OwnerOnlyActions() public {
        vm.startPrank(outsider);
        vm.expectRevert(Graveyard.Unauthorized.selector);
        graveyard.setWakeToken(address(otherToken));
        vm.expectRevert(Graveyard.Unauthorized.selector);
        graveyard.consecrate(_single(address(wake)));
        vm.expectRevert(Graveyard.Unauthorized.selector);
        graveyard.fund(100);
        vm.stopPrank();
    }

    function test_ConsecrateAddsInOrderAndEmits() public {
        MockERC20 third = new MockERC20(8);
        vm.expectEmit(true, false, false, true, address(graveyard));
        emit Consecrated(address(third));
        _consecrate(address(third));
        assertTrue(graveyard.consecrated(address(third)));
        assertEq(graveyard.consecratedCount(), 3);
        Graveyard.Tombstone[] memory page = graveyard.getTombstones(0, 100);
        assertEq(page[0].token, address(deadToken));
        assertEq(page[1].token, address(otherToken));
        assertEq(page[2].token, address(third));
        assertEq(page[2].mourners, 0);
    }

    function test_ConsecrateRejectsWakeEmptyDuplicatesAndInvalidToken() public {
        vm.startPrank(owner);
        vm.expectRevert(Graveyard.WakeCannotBeBuried.selector);
        graveyard.consecrate(_single(address(wake)));
        vm.expectRevert(abi.encodeWithSelector(Graveyard.InvalidBatchSize.selector, 0));
        graveyard.consecrate(new address[](0));
        vm.expectRevert(abi.encodeWithSelector(Graveyard.AlreadyConsecrated.selector, address(deadToken)));
        graveyard.consecrate(_single(address(deadToken)));
        vm.expectRevert(abi.encodeWithSelector(Graveyard.InvalidToken.selector, outsider));
        graveyard.consecrate(_single(outsider));
        vm.stopPrank();
        MockERC20 third = new MockERC20(18);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.AlreadyConsecrated.selector, address(third)));
        graveyard.consecrate(_pair(address(third), address(third)));
        assertFalse(graveyard.consecrated(address(third)));
        assertEq(graveyard.consecratedCount(), 2);
    }

    function test_FundRequiresApprovalAndNonzeroAndEmits() public {
        vm.startPrank(owner);
        vm.expectRevert(Graveyard.ZeroAmount.selector);
        graveyard.fund(0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(graveyard), 0, 100)
        );
        graveyard.fund(100);
        wake.approve(address(graveyard), 100);
        vm.expectEmit(true, false, false, true, address(graveyard));
        emit Funded(owner, 100);
        graveyard.fund(100);
        vm.stopPrank();
        assertEq(wake.balanceOf(address(graveyard)), FUNDING + 100);
    }

    function test_BuryEntireBalanceAndRecordsAndEvent() public {
        vm.warp(1_800_000_000);
        deadToken.mint(DEAD, 17 ether);
        uint256 reward = FUNDING / 2000;
        vm.expectEmit(true, true, false, true, address(graveyard));
        emit Buried(address(deadToken), alice, 123 ether, reward);
        assertEq(_bury(alice, address(deadToken)), reward);
        assertEq(deadToken.balanceOf(alice), 0);
        assertEq(deadToken.balanceOf(DEAD), 140 ether);
        assertEq(deadToken.balanceOf(address(graveyard)), 0);
        assertEq(wake.balanceOf(alice), reward);
        assertEq(wake.balanceOf(address(graveyard)), FUNDING - reward);
        assertTrue(graveyard.hasBuried(alice, address(deadToken)));
        Graveyard.Tombstone memory stone = graveyard.getTombstone(address(deadToken));
        assertEq(stone.firstMourner, alice);
        assertEq(stone.firstBurialTime, 1_800_000_000);
        assertEq(stone.mourners, 1);
        assertEq(stone.totalBuried, 123 ether);
        (uint256 burials, uint256 earned) = graveyard.walletRecords(alice);
        assertEq(burials, 1);
        assertEq(earned, reward);
        assertEq(graveyard.totalBurials(), 1);
        assertEq(graveyard.totalTokensBuried(), 1);
        assertEq(graveyard.totalMourners(), 1);
        assertEq(graveyard.totalWakePaidOut(), reward);
    }

    function test_BuryOnlyConsecratedPositiveBalanceWithFullAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.NotConsecrated.selector, address(wake)));
        graveyard.bury(address(wake));
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.EmptyBalance.selector, address(deadToken)));
        graveyard.bury(address(deadToken));
        vm.startPrank(alice);
        deadToken.approve(address(graveyard), 122 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(graveyard), 122 ether, 123 ether
            )
        );
        graveyard.bury(address(deadToken));
        vm.stopPrank();
        assertEq(deadToken.balanceOf(alice), 123 ether);
        assertFalse(graveyard.hasBuried(alice, address(deadToken)));
        assertEq(graveyard.totalBurials(), 0);
    }

    function test_EachWalletTokenOnlyOnceEvenAfterReceivingMore() public {
        _bury(alice, address(deadToken));
        _giveAndApprove(deadToken, alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.AlreadyBuried.selector, alice, address(deadToken)));
        graveyard.bury(address(deadToken));
        _bury(bob, address(deadToken));
        _bury(alice, address(otherToken));
        assertEq(graveyard.totalTokensBuried(), 2);
        assertEq(graveyard.totalMourners(), 2);
        assertEq(graveyard.totalBurials(), 3);
        assertEq(graveyard.getTombstone(address(deadToken)).mourners, 2);
        assertEq(graveyard.getTombstone(address(deadToken)).totalBuried, 168 ether);
    }

    function test_RewardDecayAndFirstMournerPreserved() public {
        vm.warp(500);
        uint256 first = _bury(alice, address(deadToken));
        vm.warp(600);
        uint256 second = _bury(bob, address(deadToken));
        assertEq(first, FUNDING / 2000);
        assertEq(second, (FUNDING - first) / 2000);
        assertLt(second, first);
        assertEq(graveyard.nextReward(), (FUNDING - first - second) / 2000);
        assertEq(graveyard.getTombstone(address(deadToken)).firstBurialTime, 500);
        assertEq(graveyard.getTombstone(address(deadToken)).firstMourner, alice);
        assertEq(graveyard.totalWakePaidOut(), first + second);
    }

    function test_BuryManySequentialRewardAndDifferentDecimals() public {
        uint256 first = FUNDING / 2000;
        uint256 second = (FUNDING - first) / 2000;
        vm.prank(alice);
        uint256 paid = graveyard.buryMany(_pair(address(deadToken), address(otherToken)));
        assertEq(paid, first + second);
        assertEq(wake.balanceOf(alice), paid);
        assertEq(otherToken.balanceOf(DEAD), 456 * 10 ** 6);
        assertEq(graveyard.getTombstone(address(otherToken)).totalBuried, 456 * 10 ** 6);
        assertEq(graveyard.totalMourners(), 1);
        (uint256 burials, uint256 earned) = graveyard.walletRecords(alice);
        assertEq(burials, 2);
        assertEq(earned, paid);
    }

    function test_BuryManyEmptyAnd51Rejected() public {
        vm.expectRevert(abi.encodeWithSelector(Graveyard.InvalidBatchSize.selector, 0));
        graveyard.buryMany(new address[](0));
        vm.expectRevert(abi.encodeWithSelector(Graveyard.InvalidBatchSize.selector, 51));
        graveyard.buryMany(new address[](51));
    }

    function test_BuryManyExactly50() public {
        address[] memory tokens = new address[](50);
        for (uint256 i; i < tokens.length; ++i) {
            MockERC20 token = new MockERC20(18);
            tokens[i] = address(token);
            _giveAndApprove(token, alice, i + 1);
        }
        vm.prank(owner);
        graveyard.consecrate(tokens);
        uint256 remaining = FUNDING;
        for (uint256 i; i < tokens.length; ++i) {
            remaining -= remaining / 2000;
        }
        vm.prank(alice);
        assertEq(graveyard.buryMany(tokens), FUNDING - remaining);
        assertEq(graveyard.totalBurials(), 50);
        assertEq(graveyard.totalTokensBuried(), 50);
        assertEq(graveyard.totalMourners(), 1);
        assertEq(wake.balanceOf(address(graveyard)), remaining);
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(MockERC20(tokens[i]).balanceOf(alice), 0);
            assertEq(MockERC20(tokens[i]).balanceOf(DEAD), i + 1);
        }
    }

    function test_BuryManyDuplicateRollsEverythingBack() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.AlreadyBuried.selector, alice, address(deadToken)));
        graveyard.buryMany(_pair(address(deadToken), address(deadToken)));
        _assertNoAliceBurial();
    }

    function test_BuryManyInvalidLastEntryRollsEverythingBack() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.NotConsecrated.selector, outsider));
        graveyard.buryMany(_pair(address(deadToken), outsider));
        _assertNoAliceBurial();
    }

    function test_BuryManyFailingSecondTransferRollsEverythingBack() public {
        otherToken.setBehavior(MockERC20.Behavior.Revert);
        vm.prank(alice);
        vm.expectRevert(bytes("transfer rejected"));
        graveyard.buryMany(_pair(address(deadToken), address(otherToken)));
        _assertNoAliceBurial();
        assertEq(otherToken.balanceOf(alice), 456 * 10 ** 6);
    }

    function test_EpitaphFirstBurierOnlyOnceAndEvent() public {
        _bury(alice, address(deadToken));
        _bury(bob, address(deadToken));
        vm.prank(bob);
        vm.expectRevert(Graveyard.NotFirstMourner.selector);
        graveyard.epitaph(address(deadToken), "too late");
        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(graveyard));
        emit Epitaph(address(deadToken), alice, "Rest in peace.");
        graveyard.epitaph(address(deadToken), "Rest in peace.");
        assertEq(graveyard.getTombstone(address(deadToken)).epitaphText, "Rest in peace.");
        assertTrue(graveyard.getTombstone(address(deadToken)).epitaphWritten);
        vm.prank(alice);
        vm.expectRevert(Graveyard.EpitaphAlreadyWritten.selector);
        graveyard.epitaph(address(deadToken), "rewrite");
    }

    function test_EpitaphLengthIsBytesAndCanBe64() public {
        _bury(alice, address(deadToken));
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.EpitaphTooLong.selector, 66));
        graveyard.epitaph(
            address(deadToken), unicode"ééééééééééééééééééééééééééééééééé"
        );
        graveyard.epitaph(address(deadToken), string(new bytes(64)));
        vm.stopPrank();
        assertEq(bytes(graveyard.getTombstone(address(deadToken)).epitaphText).length, 64);
    }

    function test_EmptyEpitaphConsumesRightAndUnburiedTokenHasNoEpitaph() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.NoTombstone.selector, address(deadToken)));
        graveyard.epitaph(address(deadToken), "early");
        _bury(alice, address(deadToken));
        vm.startPrank(alice);
        graveyard.epitaph(address(deadToken), "");
        vm.expectRevert(Graveyard.EpitaphAlreadyWritten.selector);
        graveyard.epitaph(address(deadToken), "second");
        vm.stopPrank();
    }

    function test_AnyoneCanLayFlowersFromOwnWakeOnly() public {
        _bury(alice, address(deadToken));
        wake.transfer(outsider, 10 ether);
        uint256 vaultBefore = wake.balanceOf(address(graveyard));
        uint256 rewardBefore = graveyard.nextReward();
        vm.startPrank(outsider);
        wake.approve(address(graveyard), 10 ether);
        vm.expectEmit(true, true, false, true, address(graveyard));
        emit Flowers(address(deadToken), outsider, 3 ether);
        graveyard.layFlowers(address(deadToken), 3 ether);
        graveyard.layFlowers(address(deadToken), 7 ether);
        vm.stopPrank();
        assertEq(wake.balanceOf(outsider), 0);
        assertEq(wake.balanceOf(DEAD), 10 ether);
        assertEq(graveyard.getTombstone(address(deadToken)).flowers, 10 ether);
        assertEq(graveyard.totalFlowersBurned(), 10 ether);
        assertEq(wake.balanceOf(address(graveyard)), vaultBefore);
        assertEq(graveyard.nextReward(), rewardBefore);
        assertEq(wake.totalSupply(), 10 ** 27);
        assertEq(graveyard.totalMourners(), 1);
    }

    function test_FlowersRequireTombstonePositiveAmountAndAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(Graveyard.NoTombstone.selector, address(deadToken)));
        graveyard.layFlowers(address(deadToken), 1);
        _bury(alice, address(deadToken));
        vm.startPrank(alice);
        vm.expectRevert(Graveyard.ZeroAmount.selector);
        graveyard.layFlowers(address(deadToken), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(graveyard), 0, 1)
        );
        graveyard.layFlowers(address(deadToken), 1);
        vm.stopPrank();
        assertEq(graveyard.totalFlowersBurned(), 0);
        assertEq(graveyard.getTombstone(address(deadToken)).flowers, 0);
    }

    function test_CanBuryReflectsEligibilityButNotAllowance() public {
        assertTrue(graveyard.canBury(alice, address(deadToken)));
        assertFalse(graveyard.canBury(outsider, address(deadToken)));
        assertFalse(graveyard.canBury(alice, address(wake)));
        assertFalse(graveyard.canBury(address(0), address(deadToken)));
        assertFalse(graveyard.canBury(DEAD, address(deadToken)));
        vm.prank(alice);
        deadToken.approve(address(graveyard), 0);
        assertTrue(graveyard.canBury(alice, address(deadToken)));
        vm.prank(alice);
        deadToken.approve(address(graveyard), 123 ether);
        _bury(alice, address(deadToken));
        _giveAndApprove(deadToken, alice, 1);
        assertFalse(graveyard.canBury(alice, address(deadToken)));
        assertTrue(graveyard.canBury(bob, address(deadToken)));
    }

    function test_PaginationBoundariesAndOverflowSafeStart() public {
        assertEq(graveyard.getTombstones(0, 0).length, 0);
        assertEq(graveyard.getTombstones(0, 100).length, 2);
        assertEq(graveyard.getTombstones(1, 100).length, 1);
        assertEq(graveyard.getTombstones(2, 100).length, 0);
        assertEq(graveyard.getTombstones(type(uint256).max, 100).length, 0);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.PageTooLarge.selector, 101));
        graveyard.getTombstones(0, 101);
        assertEq(graveyard.getTombstone(outsider).token, address(0));
    }

    function test_DirectDonationsIncreaseNextReward() public {
        wake.transfer(address(graveyard), FUNDING);
        assertEq(graveyard.nextReward(), 2 * FUNDING / 2000);
        assertEq(_bury(alice, address(deadToken)), 2 * FUNDING / 2000);
    }

    function test_NoWithdrawalRemovalOrOtherAdminEscape() public {
        string[7] memory selectors = [
            "withdraw(uint256)",
            "withdraw(address,uint256)",
            "rescueTokens(address,uint256)",
            "emergencyWithdraw()",
            "approve(address,uint256)",
            "removeToken(address)",
            "transferOwnership(address)"
        ];
        vm.startPrank(owner);
        for (uint256 i; i < selectors.length; ++i) {
            (bool success,) = address(graveyard).call(abi.encodeWithSignature(selectors[i], address(wake), FUNDING));
            assertFalse(success);
        }
        vm.stopPrank();
        assertEq(wake.balanceOf(address(graveyard)), FUNDING);
        assertEq(wake.allowance(address(graveyard), owner), 0);
        assertTrue(graveyard.consecrated(address(deadToken)));
    }

    function test_RejectsETHPlainAndWithCalldata() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        (bool plain,) = address(graveyard).call{value: 1}("");
        (bool withData,) = address(graveyard).call{value: 1}(abi.encodeCall(Graveyard.bury, (address(deadToken))));
        vm.stopPrank();
        assertFalse(plain);
        assertFalse(withData);
        assertEq(address(graveyard).balance, 0);
    }

    function _assertNoAliceBurial() private view {
        assertFalse(graveyard.hasBuried(alice, address(deadToken)));
        assertEq(graveyard.totalBurials(), 0);
        assertEq(graveyard.totalTokensBuried(), 0);
        assertEq(graveyard.totalMourners(), 0);
        assertEq(graveyard.totalWakePaidOut(), 0);
        assertEq(deadToken.balanceOf(alice), 123 ether);
        assertEq(deadToken.balanceOf(DEAD), 0);
        assertEq(deadToken.allowance(alice, address(graveyard)), 123 ether);
        assertEq(wake.balanceOf(alice), 0);
        assertEq(wake.balanceOf(address(graveyard)), FUNDING);
        assertEq(graveyard.getTombstone(address(deadToken)).firstMourner, address(0));
    }
}
