// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {BatchPermitSweeper} from "../src/BatchPermitSweeper.sol";
import {PermitToken} from "./mocks/Tokens.sol";

contract SweepHandler is Test {
    BatchPermitSweeper public sweeper;
    PermitToken public token;
    address public constant TREASURY_A = address(0x1000);
    address public constant TREASURY_B = address(0x1001);
    uint256 public minted;
    uint256 public swept;
    bool public unauthorizedSuccess;
    bool public earlyActivation;

    constructor() {
        sweeper = new BatchPermitSweeper(address(this), TREASURY_A, new address[](0));
        token = new PermitToken();
        sweeper.setTokenAllowed(address(token), true);
        sweeper.unpause();
        for (uint256 i; i < 3; ++i) {
            vm.prank(source(i));
            token.approve(address(sweeper), type(uint256).max);
        }
    }

    function source(uint256 index) public pure returns (address) { return address(uint160(0x2000 + index % 3)); }

    function deposit(uint256 index, uint128 amount) external {
        token.mint(source(index), amount);
        minted += amount;
    }

    function sweep(uint256 index) external {
        address from = source(index);
        if (sweeper.paused() || token.balanceOf(from) == 0) return;
        address[] memory sources = new address[](1);
        sources[0] = from;
        swept += sweeper.batchSweep(address(token), sources, _context());
    }

    function togglePause() external {
        if (sweeper.paused()) sweeper.unpause();
        else sweeper.pause();
    }

    function rotate(uint32 elapsed) external {
        address target = sweeper.recipient() == TREASURY_A ? TREASURY_B : TREASURY_A;
        sweeper.proposeRecipient(target);
        (uint256 id,, uint256 ready) = sweeper.pendingRecipientChange();
        if (!sweeper.paused()) sweeper.pause();
        vm.warp(block.timestamp + uint256(elapsed) % (48 hours));
        (bool success,) = address(sweeper).call(abi.encodeCall(sweeper.activateRecipient, (id, target)));
        if (success && block.timestamp < ready) earlyActivation = true;
    }

    function unauthorizedAttempt(uint256 index) external {
        address[] memory sources = new address[](1);
        sources[0] = source(index);
        bytes memory data = abi.encodeCall(sweeper.batchSweep, (address(token), sources, _context()));
        vm.prank(address(0xBAD));
        (bool success,) = address(sweeper).call(data);
        if (success) unauthorizedSuccess = true;
    }

    function _context() private view returns (BatchPermitSweeper.SweepContext memory) {
        return BatchPermitSweeper.SweepContext(sweeper.recipient(), sweeper.configVersion(), block.timestamp + 600);
    }
}

contract SweepInvariantTest is StdInvariant, Test {
    SweepHandler private handler;

    function setUp() public {
        handler = new SweepHandler();
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.sweep.selector;
        selectors[2] = handler.togglePause.selector;
        selectors[3] = handler.rotate.selector;
        selectors[4] = handler.unauthorizedAttempt.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantFundsConservedAndNeverCustodied() public view {
        PermitToken asset = handler.token();
        uint256 received = asset.balanceOf(handler.TREASURY_A()) + asset.balanceOf(handler.TREASURY_B());
        uint256 remaining;
        for (uint256 i; i < 3; ++i) remaining += asset.balanceOf(handler.source(i));
        assertEq(received, handler.swept());
        assertEq(received + remaining, handler.minted());
        assertEq(asset.balanceOf(address(handler.sweeper())), 0);
    }

    function invariantAuthorizationAndTimelockHold() public view {
        assertFalse(handler.unauthorizedSuccess());
        assertFalse(handler.earlyActivation());
        assertEq(handler.sweeper().owner(), address(handler));
        address recipient = handler.sweeper().recipient();
        assertTrue(recipient == handler.TREASURY_A() || recipient == handler.TREASURY_B());
    }
}
