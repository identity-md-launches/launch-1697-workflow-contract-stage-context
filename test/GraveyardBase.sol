// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Graveyard} from "../src/Graveyard.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

abstract contract GraveyardBase is Test {
    LaunchToken internal wake;
    Graveyard internal graveyard;
    MockERC20 internal deadToken;
    MockERC20 internal otherToken;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal outsider = makeAddr("outsider");
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant FUNDING = 1_000_000 ether;

    function setUp() public virtual {
        wake = new LaunchToken();
        graveyard = new Graveyard(owner);
        deadToken = new MockERC20(18);
        otherToken = new MockERC20(6);
        vm.startPrank(owner);
        graveyard.setWakeToken(address(wake));
        graveyard.consecrate(_pair(address(deadToken), address(otherToken)));
        vm.stopPrank();
        wake.transfer(owner, 2 * FUNDING);
        vm.startPrank(owner);
        wake.approve(address(graveyard), FUNDING);
        graveyard.fund(FUNDING);
        vm.stopPrank();
        _giveAndApprove(deadToken, alice, 123 ether);
        _giveAndApprove(deadToken, bob, 45 ether);
        _giveAndApprove(otherToken, alice, 456 * 10 ** 6);
        _giveAndApprove(otherToken, bob, 789 * 10 ** 6);
    }

    function _giveAndApprove(MockERC20 token, address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(graveyard), amount);
    }

    function _consecrate(address token) internal {
        vm.prank(owner);
        graveyard.consecrate(_single(token));
    }

    function _bury(address user, address token) internal returns (uint256) {
        vm.prank(user);
        return graveyard.bury(token);
    }

    function _single(address a) internal pure returns (address[] memory result) {
        result = new address[](1);
        result[0] = a;
    }

    function _pair(address a, address b) internal pure returns (address[] memory result) {
        result = new address[](2);
        result[0] = a;
        result[1] = b;
    }
}
