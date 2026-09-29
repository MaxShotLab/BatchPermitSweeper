// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract PermitToken is ERC20, ERC20Permit {
    enum Mode {
        Normal,
        ReturnFalse,
        NoTransfer,
        Fee
    }

    Mode public mode;
    mapping(address => bool) public blocked;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    error Blocked(address account);

    constructor() ERC20("Test Token", "TEST") ERC20Permit("Test Token") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setMode(Mode next) external {
        mode = next;
    }

    function setBlocked(address account, bool status) external {
        blocked[account] = status;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (mode == Mode.ReturnFalse) return false;
        if (mode == Mode.NoTransfer) return true;
        bool success = super.transferFrom(from, to, amount);
        if (callbackTarget != address(0)) {
            (callbackSucceeded,) = callbackTarget.call(callbackData);
        }
        return success;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blocked[from]) revert Blocked(from);
        if (blocked[to]) revert Blocked(to);
        if (mode == Mode.Fee && from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @dev Deliberately omits return data and permit, as some legacy ERC20 tokens do.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 value) external {
        allowance[msg.sender][spender] = value;
    }

    function transfer(address to, uint256 value) external {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
    }

    function transferFrom(address from, address to, uint256 value) external {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= value, "ALLOWANCE");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        balanceOf[from] -= value;
        balanceOf[to] += value;
    }
}
