// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GraveyardBase} from "./GraveyardBase.sol";
import {Graveyard} from "../src/Graveyard.sol";
import {MockERC20, CallbackToken, NoReturnToken} from "./mocks/MockERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract GraveyardAdversarialTest is GraveyardBase {
    function test_NoReturnTokenCanBeBuried() public {
        NoReturnToken legacy = new NoReturnToken();
        _consecrate(address(legacy));
        legacy.mint(alice, 123);
        vm.startPrank(alice);
        legacy.approve(address(graveyard), 123);
        uint256 reward = graveyard.bury(address(legacy));
        vm.stopPrank();
        assertEq(legacy.balanceOf(alice), 0);
        assertEq(legacy.balanceOf(DEAD), 123);
        assertEq(reward, FUNDING / 2000);
    }

    function test_FalseReturnTokenCannotConsumeBurialOrRewards() public {
        deadToken.setBehavior(MockERC20.Behavior.ReturnFalse);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(deadToken)));
        graveyard.bury(address(deadToken));
        _assertFailedBurial(graveyard, deadToken);
    }

    function test_TaxedNoOpAndReflectingTokensCannotEarnRewards() public {
        MockERC20.Behavior[3] memory behaviors =
            [MockERC20.Behavior.Tax, MockERC20.Behavior.NoOp, MockERC20.Behavior.Reflect];
        for (uint256 i; i < behaviors.length; ++i) {
            deadToken.setBehavior(behaviors[i]);
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(Graveyard.InexactTransfer.selector, address(deadToken)));
            graveyard.bury(address(deadToken));
            _assertFailedBurial(graveyard, deadToken);
        }
        deadToken.setBehavior(MockERC20.Behavior.Normal);
        assertEq(_bury(alice, address(deadToken)), FUNDING / 2000);
    }

    function test_RevertingTokenCannotConsumeBurial() public {
        deadToken.setBehavior(MockERC20.Behavior.Revert);
        vm.prank(alice);
        vm.expectRevert(bytes("transfer rejected"));
        graveyard.bury(address(deadToken));
        _assertFailedBurial(graveyard, deadToken);
    }

    function test_FailedWakePayoutRollsBackBurnAndRecordsAndAllowsRetry() public {
        MockERC20 rewardToken = new MockERC20(18);
        Graveyard fresh = _freshWithWake(address(rewardToken));
        rewardToken.mint(address(fresh), FUNDING);
        rewardToken.setFailPayout(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(rewardToken)));
        fresh.bury(address(deadToken));
        _assertFailedBurial(fresh, deadToken);
        assertEq(rewardToken.balanceOf(address(fresh)), FUNDING);
        assertEq(rewardToken.balanceOf(alice), 0);
        rewardToken.setFailPayout(false);
        vm.prank(alice);
        assertEq(fresh.bury(address(deadToken)), FUNDING / 2000);
        assertEq(rewardToken.balanceOf(alice), FUNDING / 2000);
    }

    function test_InexactFundingRevertsWithoutChangingVault() public {
        MockERC20 rewardToken = new MockERC20(18);
        Graveyard fresh = _freshWithWake(address(rewardToken));
        rewardToken.mint(owner, 100);
        vm.prank(owner);
        rewardToken.approve(address(fresh), 100);
        rewardToken.setBehavior(MockERC20.Behavior.Tax);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.InexactTransfer.selector, address(rewardToken)));
        fresh.fund(100);
        assertEq(rewardToken.balanceOf(address(fresh)), 0);
        assertEq(rewardToken.balanceOf(owner), 100);
    }

    function test_FailedAndInexactFlowersRollBackRecords() public {
        MockERC20 rewardToken = new MockERC20(18);
        Graveyard fresh = _freshWithWake(address(rewardToken));
        vm.prank(alice);
        fresh.bury(address(deadToken));
        rewardToken.mint(bob, 100);
        vm.prank(bob);
        rewardToken.approve(address(fresh), 100);
        rewardToken.setBehavior(MockERC20.Behavior.ReturnFalse);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(rewardToken)));
        fresh.layFlowers(address(deadToken), 100);
        rewardToken.setBehavior(MockERC20.Behavior.Tax);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.InexactTransfer.selector, address(rewardToken)));
        fresh.layFlowers(address(deadToken), 100);
        assertEq(fresh.totalFlowersBurned(), 0);
        assertEq(fresh.getTombstone(address(deadToken)).flowers, 0);
        assertEq(rewardToken.balanceOf(bob), 100);
        assertEq(rewardToken.balanceOf(DEAD), 0);
    }

    function test_ReentrancyAcrossEveryMutationDuringBurialIsBlocked() public {
        CallbackToken attacker = new CallbackToken();
        _consecrate(address(attacker));
        bytes[7] memory payloads = [
            abi.encodeCall(Graveyard.bury, (address(otherToken))),
            abi.encodeCall(Graveyard.buryMany, (_single(address(otherToken)))),
            abi.encodeCall(Graveyard.epitaph, (address(attacker), "callback")),
            abi.encodeCall(Graveyard.layFlowers, (address(attacker), 1)),
            abi.encodeCall(Graveyard.setWakeToken, (address(attacker))),
            abi.encodeCall(Graveyard.consecrate, (_single(address(attacker)))),
            abi.encodeCall(Graveyard.fund, (1))
        ];
        for (uint256 i; i < payloads.length; ++i) {
            address mourner = makeAddr(string.concat("mourner", vm.toString(i)));
            _giveAndApprove(attacker, mourner, 10);
            attacker.configure(address(graveyard), payloads[i], false, false);
            _bury(mourner, address(attacker));
            assertFalse(attacker.callbackSucceeded());
            assertEq(
                attacker.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
            );
        }
        assertEq(graveyard.totalBurials(), 7);
        assertEq(graveyard.getTombstone(address(attacker)).mourners, 7);
        assertEq(graveyard.totalFlowersBurned(), 0);
    }

    function test_ReentrancyPropagatedFailureRollsBackEntireBurial() public {
        CallbackToken attacker = new CallbackToken();
        _consecrate(address(attacker));
        _giveAndApprove(attacker, alice, 123 ether);
        attacker.configure(address(graveyard), abi.encodeCall(Graveyard.bury, (address(attacker))), false, true);
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        graveyard.bury(address(attacker));
        _assertFailedBurial(graveyard, attacker);
        assertEq(wake.balanceOf(address(graveyard)), FUNDING);
    }

    function test_ReentrancyFromWakePayoutFundingAndFlowersIsBlocked() public {
        CallbackToken rewardToken = new CallbackToken();
        Graveyard fresh = _freshWithWake(address(rewardToken));
        bytes memory payload = abi.encodeCall(Graveyard.bury, (address(otherToken)));
        rewardToken.configure(address(fresh), payload, false, false);
        rewardToken.mint(owner, FUNDING);
        vm.startPrank(owner);
        rewardToken.approve(address(fresh), FUNDING);
        fresh.fund(FUNDING);
        vm.stopPrank();
        _assertCallbackBlocked(rewardToken);
        rewardToken.configure(address(fresh), payload, true, false);
        vm.prank(alice);
        fresh.bury(address(deadToken));
        _assertCallbackBlocked(rewardToken);
        rewardToken.configure(address(fresh), payload, false, false);
        vm.startPrank(alice);
        rewardToken.approve(address(fresh), 1);
        fresh.layFlowers(address(deadToken), 1);
        vm.stopPrank();
        _assertCallbackBlocked(rewardToken);
        assertEq(fresh.totalBurials(), 1);
        assertEq(fresh.totalFlowersBurned(), 1);
        assertEq(fresh.totalWakePaidOut(), FUNDING / 2000);
    }

    function test_CanBuryHandlesBrokenBalanceAndLostCode() public {
        bytes memory query = abi.encodeWithSignature("balanceOf(address)", alice);
        vm.mockCallRevert(address(deadToken), query, bytes("broken"));
        assertFalse(graveyard.canBury(alice, address(deadToken)));
        vm.clearMockedCalls();
        vm.mockCall(address(deadToken), query, hex"01");
        assertFalse(graveyard.canBury(alice, address(deadToken)));
        vm.clearMockedCalls();
        vm.etch(address(deadToken), hex"");
        assertFalse(graveyard.canBury(alice, address(deadToken)));
    }

    function testFuzz_RewardRoundingAllUint256Balances(uint256 vaultBalance) public {
        MockERC20 rewardToken = new MockERC20(18);
        Graveyard fresh = _freshWithWake(address(rewardToken));
        rewardToken.mint(address(fresh), vaultBalance);
        uint256 quoted = fresh.nextReward();
        vm.prank(alice);
        uint256 paid = fresh.bury(address(deadToken));
        assertEq(paid, quoted);
        assertEq(paid, vaultBalance / 2000);
        assertEq(rewardToken.balanceOf(address(fresh)), vaultBalance - paid);
        assertEq(rewardToken.balanceOf(alice), paid);
        assertEq(fresh.totalWakePaidOut(), paid);
        if (vaultBalance > 0) assertGt(rewardToken.balanceOf(address(fresh)), 0);
        assertEq(deadToken.balanceOf(alice), 0);
    }

    function test_EmptyAndDustVaultAllowBurialWithZeroReward() public {
        uint256[4] memory balances = [uint256(0), uint256(1), uint256(1999), uint256(2000)];
        for (uint256 i; i < balances.length; ++i) {
            MockERC20 rewardToken = new MockERC20(18);
            Graveyard fresh = _freshWithWake(address(rewardToken));
            rewardToken.mint(address(fresh), balances[i]);
            deadToken.mint(alice, 1);
            vm.startPrank(alice);
            deadToken.approve(address(fresh), deadToken.balanceOf(alice));
            uint256 paid = fresh.bury(address(deadToken));
            vm.stopPrank();
            assertEq(paid, balances[i] / 2000);
            assertTrue(fresh.hasBuried(alice, address(deadToken)));
            assertEq(rewardToken.balanceOf(address(fresh)), balances[i] - paid);
        }
    }

    function testFuzz_ConservationThroughSequentialBurials(uint96 funding, uint8 rawCount) public {
        uint256 count = bound(rawCount, 1, 50);
        MockERC20 rewardToken = new MockERC20(18);
        Graveyard fresh = _freshWithWake(address(rewardToken));
        rewardToken.mint(address(fresh), funding);
        uint256 remaining = funding;
        uint256 sumPaid;
        for (uint256 i; i < count; ++i) {
            address mourner = address(uint160(0x1000 + i));
            deadToken.mint(mourner, 1);
            vm.startPrank(mourner);
            deadToken.approve(address(fresh), 1);
            uint256 reward = fresh.bury(address(deadToken));
            vm.stopPrank();
            assertEq(reward, remaining / 2000);
            sumPaid += reward;
            remaining -= reward;
            assertEq(rewardToken.balanceOf(mourner), reward);
        }
        assertEq(rewardToken.balanceOf(address(fresh)) + sumPaid, funding);
        assertEq(fresh.totalWakePaidOut(), sumPaid);
        assertEq(fresh.totalBurials(), count);
        assertEq(fresh.totalMourners(), count);
        assertEq(fresh.totalTokensBuried(), 1);
        assertEq(fresh.getTombstone(address(deadToken)).totalBuried, count);
        if (funding > 0) assertGt(remaining, 0);
    }

    function testFuzz_FullBalanceOfAnyPrecisionIsBurned(uint128 amount, uint8 precision) public {
        vm.assume(amount > 0);
        MockERC20 token = new MockERC20(precision);
        _consecrate(address(token));
        _giveAndApprove(token, alice, amount);
        _bury(alice, address(token));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(DEAD), amount);
        assertEq(graveyard.getTombstone(address(token)).totalBuried, amount);
        assertEq(wake.balanceOf(alice), FUNDING / 2000);
    }

    function _freshWithWake(address rewardToken) private returns (Graveyard fresh) {
        fresh = new Graveyard(owner);
        vm.startPrank(owner);
        fresh.setWakeToken(rewardToken);
        fresh.consecrate(_single(address(deadToken)));
        vm.stopPrank();
        vm.prank(alice);
        deadToken.approve(address(fresh), 123 ether);
    }

    function _assertFailedBurial(Graveyard target, MockERC20 token) private view {
        assertFalse(target.hasBuried(alice, address(token)));
        assertEq(target.totalWakePaidOut(), 0);
        assertEq(target.totalBurials(), 0);
        assertEq(target.totalMourners(), 0);
        assertEq(target.getTombstone(address(token)).mourners, 0);
        assertEq(token.balanceOf(alice), 123 ether);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(wake.balanceOf(alice), 0);
    }

    function _assertCallbackBlocked(CallbackToken token) private view {
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }
}
