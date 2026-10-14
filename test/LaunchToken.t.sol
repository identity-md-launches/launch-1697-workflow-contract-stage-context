// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LaunchTokenTest is Test {
    LaunchToken private token;
    address private alice = makeAddr("alice");
    address private spender = makeAddr("spender");
    uint256 private constant SUPPLY = 10 ** 27;

    function setUp() public {
        token = new LaunchToken();
    }

    function test_MetadataAndEntireSupply() public view {
        assertEq(token.name(), "A Funeral For Every Dead Token");
        assertEq(token.symbol(), "WAKE");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testFuzz_TransfersPreserveSupplyAndMoveExactAmount(uint256 raw) public {
        uint256 amount = bound(raw, 0, SUPPLY);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ApprovalAndTransferFrom() public {
        token.approve(spender, 100);
        vm.prank(spender);
        token.transferFrom(address(this), alice, 60);
        assertEq(token.allowance(address(this), spender), 40);
        assertEq(token.balanceOf(alice), 60);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 40, 41));
        token.transferFrom(address(this), alice, 41);
    }

    function test_InsufficientBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(spender, 1);
    }

    function test_ZeroRecipientReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_NoAdminMintPauseTaxOrUpgradeSurface() public {
        string[12] memory selectors = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "setMinter(address)",
            "setFee(uint256)",
            "blacklist(address)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool success,) = address(token).call(abi.encodeWithSignature(selectors[i], alice, 100));
            assertFalse(success);
            vm.prank(alice);
            (success,) = address(token).call(abi.encodeWithSignature(selectors[i], alice, 100));
            assertFalse(success);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }
}
