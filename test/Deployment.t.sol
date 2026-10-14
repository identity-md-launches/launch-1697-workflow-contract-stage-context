// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Graveyard} from "../src/Graveyard.sol";

contract FactoryHarness {
    function deploy(address owner) external returns (LaunchToken token, Graveyard graveyard) {
        token = new LaunchToken{salt: bytes32(uint256(1))}();
        graveyard = new Graveyard{salt: bytes32(uint256(2))}(owner);
    }
}

contract DeploymentTest is Test {
    function test_FactoryDeploymentOnEmptyChainPreservesSupplyAndExplicitOwner() public {
        address launchOwner = makeAddr("launchOwner");
        assertEq(launchOwner.code.length, 0);
        FactoryHarness factory = new FactoryHarness();
        (LaunchToken token, Graveyard graveyard) = factory.deploy(launchOwner);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(address(factory)), 10 ** 27);
        assertEq(token.balanceOf(address(graveyard)), 0);
        assertEq(graveyard.owner(), launchOwner);
        assertNotEq(graveyard.owner(), address(factory));
        assertNotEq(graveyard.owner(), tx.origin);
        assertEq(address(graveyard.wakeToken()), address(0));
        vm.prank(address(factory));
        vm.expectRevert(Graveyard.Unauthorized.selector);
        graveyard.setWakeToken(address(token));
        vm.prank(launchOwner);
        graveyard.setWakeToken(address(token));
        assertEq(token.balanceOf(address(factory)), 10 ** 27);
        _checkRuntime(address(token));
        _checkRuntime(address(graveyard));
    }

    function _checkRuntime(address deployed) private view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden opcode");
        }
    }
}
