// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    enum Behavior {
        Normal,
        ReturnFalse,
        Revert,
        NoOp,
        Tax,
        Reflect
    }

    Behavior public behavior;
    bool public failPayout;
    uint8 private immutable _decimals;

    constructor(uint8 precision) ERC20("Dead Token", "DEAD") {
        _decimals = precision;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBehavior(Behavior value) external {
        behavior = value;
    }

    function setFailPayout(bool value) external {
        failPayout = value;
    }

    function transfer(address to, uint256 value) public virtual override returns (bool) {
        if (failPayout) return false;
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public virtual override returns (bool) {
        if (behavior == Behavior.ReturnFalse) return false;
        if (behavior == Behavior.Revert) revert("transfer rejected");
        if (behavior == Behavior.NoOp) return true;
        if (behavior == Behavior.Tax) {
            _spendAllowance(from, msg.sender, value);
            uint256 tax = value / 10;
            _transfer(from, to, value - tax);
            _burn(from, tax);
            return true;
        }
        bool success = super.transferFrom(from, to, value);
        if (behavior == Behavior.Reflect) _mint(from, 1);
        return success;
    }
}

contract CallbackToken is MockERC20 {
    address public target;
    bytes public payload;
    bool public attackOnTransfer;
    bool public propagateFailure;
    bool public callbackSucceeded;
    bytes public callbackResult;

    constructor() MockERC20(18) {}

    function configure(address callTarget, bytes calldata callData, bool onTransfer, bool propagate) external {
        target = callTarget;
        payload = callData;
        attackOnTransfer = onTransfer;
        propagateFailure = propagate;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        bool success = super.transfer(to, value);
        if (attackOnTransfer) _callback();
        return success;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        bool success = super.transferFrom(from, to, value);
        if (!attackOnTransfer) _callback();
        return success;
    }

    function _callback() private {
        if (target == address(0)) return;
        (callbackSucceeded, callbackResult) = target.call(payload);
        if (propagateFailure && !callbackSucceeded) {
            bytes memory reason = callbackResult;
            assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }
    }
}

/// @dev An older ERC-20 shape: transfer/transferFrom return no bytes on success.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
