// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TestBase} from "./TestBase.sol";
import {BatchPermitSweeper} from "../src/BatchPermitSweeper.sol";
import {PermitToken, NoReturnToken} from "./mocks/Tokens.sol";

contract SweepingTest is TestBase {
    function testWorkerSweepsFullBalance() public {
        _fundAndApprove(alice, 100, type(uint256).max);
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.prank(worker);
        assertEq(sweeper.batchSweep(address(token), _one(alice), context), 100);
        assertEq(token.balanceOf(treasury), 100);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(sweeper)), 0);
    }

    function testOwnerCanSweep() public {
        _fundAndApprove(alice, 7, 7);
        sweeper.batchSweep(address(token), _one(alice), _context());
        assertEq(token.balanceOf(treasury), 7);
    }

    function testNewDepositsAreIncludedAndAllowanceIsReusable() public {
        _fundAndApprove(alice, 100, type(uint256).max);
        BatchPermitSweeper.SweepContext memory context = _context();
        token.mint(alice, 20);
        sweeper.batchSweep(address(token), _one(alice), context);
        token.mint(alice, 30);
        sweeper.batchSweep(address(token), _one(alice), context);
        assertEq(token.balanceOf(treasury), 150);
    }

    function testUnauthorizedCallerCannotSweep() public {
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.NotAuthorized.selector, alice));
        sweeper.batchSweep(address(token), _one(alice), context);
    }

    function testEmptyBatchRejected() public {
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.expectRevert(BatchPermitSweeper.EmptyBatch.selector);
        sweeper.batchSweep(address(token), new address[](0), context);
    }

    function testUnlistedTokenRejected() public {
        sweeper.setTokenAllowed(address(token), false);
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.TokenNotAllowed.selector, address(token)));
        sweeper.batchSweep(address(token), _one(alice), context);
    }

    function testNoCodeTokenRejected() public {
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.InvalidToken.selector, address(0xBAD)));
        sweeper.batchSweep(address(0xBAD), _one(alice), context);
    }

    function testZeroBalanceRejected() public {
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.ZeroBalance.selector, alice));
        sweeper.batchSweep(address(token), _one(alice), context);
    }

    function testInsufficientAllowanceDoesNotPartiallySweep() public {
        _fundAndApprove(alice, 101, 100);
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.InsufficientAllowance.selector, alice, 100, 101));
        sweeper.batchSweep(address(token), _one(alice), context);
        assertEq(token.balanceOf(alice), 101);
    }

    function testDuplicateSourcesRejected() public {
        address[] memory sources = new address[](2);
        sources[0] = alice;
        sources[1] = alice;
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.SourcesNotStrictlyIncreasing.selector, alice, alice));
        sweeper.batchSweep(address(token), sources, context);
    }

    function testUnsortedSourcesRejected() public {
        address[] memory sources = _two();
        (sources[0], sources[1]) = (sources[1], sources[0]);
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.expectRevert(
            abi.encodeWithSelector(BatchPermitSweeper.SourcesNotStrictlyIncreasing.selector, sources[0], sources[1])
        );
        sweeper.batchSweep(address(token), sources, context);
    }

    function testInvalidSourcesRejected() public {
        BatchPermitSweeper.SweepContext memory context = _context();
        address[3] memory invalid = [address(0), address(sweeper), treasury];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.InvalidSource.selector, invalid[i]));
            sweeper.batchSweep(address(token), _one(invalid[i]), context);
        }
    }

    function testAllTransfersRollBackWhenLaterSourceFails() public {
        address[] memory sources = _two();
        _fundAndApprove(sources[0], 100, 100);
        _fundAndApprove(sources[1], 200, 200);
        token.setBlocked(sources[1], true);
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.expectRevert(abi.encodeWithSelector(PermitToken.Blocked.selector, sources[1]));
        sweeper.batchSweep(address(token), sources, context);
        assertEq(token.balanceOf(sources[0]), 100);
        assertEq(token.allowance(sources[0], address(sweeper)), 100);
        assertEq(token.balanceOf(treasury), 0);
    }

    function testFeeTokenRejectedAndRolledBack() public {
        _fundAndApprove(alice, 100, 100);
        token.setMode(PermitToken.Mode.Fee);
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.ReceivedAmountMismatch.selector, 100, 0, 99));
        sweeper.batchSweep(address(token), _one(alice), context);
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.totalSupply(), 100);
    }

    function testFalseReturnRejected() public {
        _fundAndApprove(alice, 100, 100);
        token.setMode(PermitToken.Mode.ReturnFalse);
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.expectRevert();
        sweeper.batchSweep(address(token), _one(alice), context);
        assertEq(token.balanceOf(alice), 100);
    }

    function testSuccessWithoutTransferRejected() public {
        _fundAndApprove(alice, 100, 100);
        token.setMode(PermitToken.Mode.NoTransfer);
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.ReceivedAmountMismatch.selector, 100, 0, 0));
        sweeper.batchSweep(address(token), _one(alice), context);
    }

    function testNoReturnTokenWorksWithExistingAllowance() public {
        NoReturnToken asset = new NoReturnToken();
        sweeper.setTokenAllowed(address(asset), true);
        asset.mint(alice, 100);
        vm.prank(alice);
        asset.approve(address(sweeper), 100);
        sweeper.batchSweep(address(asset), _one(alice), _context());
        assertEq(asset.balanceOf(treasury), 100);
    }

    function testRecipientMismatchRejected() public {
        BatchPermitSweeper.SweepContext memory context = _context();
        context.expectedRecipient = alice;
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.RecipientMismatch.selector, alice, treasury));
        sweeper.batchSweep(address(token), _one(alice), context);
    }

    function testExpiredAndZeroDeadlinesRejected() public {
        BatchPermitSweeper.SweepContext memory context = _context();
        context.validUntil = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.BatchExpired.selector, context.validUntil));
        sweeper.batchSweep(address(token), _one(alice), context);
        context.validUntil = 0;
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.BatchExpired.selector, 0));
        sweeper.batchSweep(address(token), _one(alice), context);
    }

    function testExactDeadlineIsAccepted() public {
        _fundAndApprove(alice, 1, 1);
        BatchPermitSweeper.SweepContext memory context = _context();
        context.validUntil = block.timestamp;
        sweeper.batchSweep(address(token), _one(alice), context);
        assertEq(token.balanceOf(treasury), 1);
    }

    function testCallbackCannotPauseEvenWhenTokenIsOperator() public {
        _fundAndApprove(alice, 100, 100);
        sweeper.setOperator(address(token), true);
        token.setCallback(address(sweeper), abi.encodeCall(sweeper.pause, ()));
        sweeper.batchSweep(address(token), _one(alice), _context());
        assertFalse(token.callbackSucceeded());
        assertFalse(sweeper.paused());
        assertEq(token.balanceOf(treasury), 100);
    }

    function testCallbackCannotChangeConfigEvenWhenTokenIsOwner() public {
        _fundAndApprove(alice, 100, 100);
        sweeper.transferOwnership(address(token));
        vm.prank(address(token));
        sweeper.acceptOwnership();
        token.setCallback(address(sweeper), abi.encodeCall(sweeper.setOperator, (bob, true)));
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.prank(worker);
        sweeper.batchSweep(address(token), _one(alice), context);
        assertFalse(token.callbackSucceeded());
        assertFalse(sweeper.isOperator(bob));
    }

    function testFuzzFullBalanceIsConserved(uint128 amount, uint128 additional) public {
        uint256 total = uint256(amount) + additional;
        vm.assume(total > 0);
        _fundAndApprove(alice, amount, type(uint256).max);
        token.mint(alice, additional);
        uint256 version = sweeper.configVersion();
        sweeper.batchSweep(address(token), _one(alice), _context());
        assertEq(token.balanceOf(treasury), total);
        assertEq(token.balanceOf(alice), 0);
        assertEq(sweeper.configVersion(), version);
    }
}
