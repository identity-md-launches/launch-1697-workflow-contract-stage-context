// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GraveyardBase} from "./GraveyardBase.sol";
import {Graveyard} from "src/Graveyard.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract DonationDuringBurialToken is MockERC20 {
    LaunchToken private immutable wake;
    address private immutable cemetery;
    uint256 private immutable donation;

    constructor(LaunchToken reward, address target, uint256 amount) MockERC20(18) {
        wake = reward;
        cemetery = target;
        donation = amount;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool result = super.transferFrom(from, to, amount);
        wake.transfer(cemetery, donation);
        return result;
    }
}

contract GraveyardBoundaryPropertiesTest is GraveyardBase {
    function test_DonationDuringTransferAffectsOnlySubsequentBatchReward() public {
        uint256 donation = 2000 ether;
        DonationDuringBurialToken token = new DonationDuringBurialToken(wake, address(graveyard), donation);
        _consecrate(address(token));
        wake.transfer(address(token), donation);
        _giveAndApprove(token, alice, 1);
        uint256 first = FUNDING / 2000;
        uint256 second = (FUNDING - first + donation) / 2000;
        vm.prank(alice);
        uint256 paid = graveyard.buryMany(_pair(address(token), address(deadToken)));
        assertEq(paid, first + second);
        assertEq(wake.balanceOf(alice), paid);
        assertEq(wake.balanceOf(address(token)), 0);
        assertEq(wake.balanceOf(address(graveyard)) + paid, FUNDING + donation);
        assertEq(graveyard.totalWakePaidOut(), paid);
    }

    function test_PaginationAcrossMoreThanOneFullPagePreservesOrder() public {
        address[] memory extra = new address[](103);
        for (uint256 i; i < extra.length; ++i) {
            extra[i] = address(new MockERC20(18));
        }
        vm.prank(owner);
        graveyard.consecrate(extra);
        assertEq(graveyard.consecratedCount(), 105);
        Graveyard.Tombstone[] memory first = graveyard.getTombstones(0, 100);
        Graveyard.Tombstone[] memory last = graveyard.getTombstones(100, 100);
        assertEq(first.length, 100);
        assertEq(last.length, 5);
        assertEq(first[0].token, address(deadToken));
        assertEq(first[1].token, address(otherToken));
        for (uint256 i = 2; i < first.length; ++i) {
            assertEq(first[i].token, extra[i - 2]);
        }
        for (uint256 i; i < last.length; ++i) {
            assertEq(last[i].token, extra[98 + i]);
        }
        assertEq(graveyard.getTombstones(105, 100).length, 0);
        assertEq(graveyard.getTombstones(type(uint256).max, 100).length, 0);
        vm.expectRevert(abi.encodeWithSelector(Graveyard.PageTooLarge.selector, 101));
        graveyard.getTombstones(type(uint256).max, 101);
    }

    function test_FlowerInsufficientBalanceRestoresFiniteAllowanceAndRecords() public {
        _bury(alice, address(deadToken));
        uint256 balance = wake.balanceOf(alice);
        uint256 vault = wake.balanceOf(address(graveyard));
        vm.startPrank(alice);
        wake.approve(address(graveyard), balance + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, balance + 1)
        );
        graveyard.layFlowers(address(deadToken), balance + 1);
        vm.stopPrank();
        assertEq(wake.allowance(alice, address(graveyard)), balance + 1);
        assertEq(wake.balanceOf(alice), balance);
        assertEq(wake.balanceOf(address(graveyard)), vault);
        assertEq(wake.balanceOf(DEAD), 0);
        assertEq(graveyard.getTombstone(address(deadToken)).flowers, 0);
        assertEq(graveyard.totalFlowersBurned(), 0);
        assertEq(graveyard.totalBurials(), 1);
    }

    function test_MaximumUint256BurialDoesNotOverflow() public {
        MockERC20 token = new MockERC20(0);
        _consecrate(address(token));
        _giveAndApprove(token, alice, type(uint256).max);
        _bury(alice, address(token));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(DEAD), type(uint256).max);
        assertEq(token.totalSupply(), type(uint256).max);
        assertEq(graveyard.getTombstone(address(token)).totalBuried, type(uint256).max);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_EpitaphBytesRoundTripAndOversizeDoesNotConsumeRight(bytes memory text) public {
        _bury(alice, address(deadToken));
        vm.startPrank(alice);
        if (text.length > 64) {
            vm.expectRevert(abi.encodeWithSelector(Graveyard.EpitaphTooLong.selector, text.length));
            graveyard.epitaph(address(deadToken), string(text));
            assertFalse(graveyard.getTombstone(address(deadToken)).epitaphWritten);
            graveyard.epitaph(address(deadToken), "retry");
            assertEq(graveyard.getTombstone(address(deadToken)).epitaphText, "retry");
        } else {
            graveyard.epitaph(address(deadToken), string(text));
            assertEq(bytes(graveyard.getTombstone(address(deadToken)).epitaphText), text);
        }
        vm.expectRevert(Graveyard.EpitaphAlreadyWritten.selector);
        graveyard.epitaph(address(deadToken), "rewrite");
        vm.stopPrank();
    }
}

contract LaunchTokenBoundaryPropertiesTest is Test {
    LaunchToken private token;
    address private alice;
    address private spender;

    function setUp() public {
        token = new LaunchToken();
        alice = makeAddr("boundary recipient");
        spender = makeAddr("boundary spender");
    }

    function test_FullSupplyInfiniteAllowanceAndSelfTransfer() public {
        uint256 supply = token.totalSupply();
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, supply));
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(address(this)), 0);
        vm.prank(alice);
        assertTrue(token.transfer(alice, supply));
        assertEq(token.balanceOf(alice), supply);
        vm.prank(alice);
        assertTrue(token.transfer(address(this), supply));
        assertEq(token.balanceOf(address(this)), supply);
        assertEq(token.totalSupply(), supply);
    }

    function test_ZeroTransfersAndRevokedApproval() public {
        vm.prank(alice);
        assertTrue(token.transfer(spender, 0));
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, address(this), 0));
        token.approve(spender, 1);
        token.approve(spender, 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(address(this), alice, 1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_ZeroSpenderAndZeroReceiverRejectWithoutChangingAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        token.approve(spender, 42);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(address(this), address(0), 42);
        assertEq(token.allowance(address(this), spender), 42);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FailedTransferFromRestoresSpentAllowance(uint256 rawBalance, uint256 rawAllowance) public {
        uint256 supply = token.totalSupply();
        uint256 balance = bound(rawBalance, 0, supply);
        uint256 allowance = bound(rawAllowance, balance + 1, type(uint256).max);
        token.transfer(alice, balance);
        vm.prank(alice);
        token.approve(spender, allowance);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, balance + 1)
        );
        token.transferFrom(alice, address(this), balance + 1);
        assertEq(token.allowance(alice, spender), allowance);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(address(this)), supply - balance);
        assertEq(token.totalSupply(), supply);
    }
}
