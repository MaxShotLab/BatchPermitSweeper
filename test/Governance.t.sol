// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {TestBase} from "./TestBase.sol";
import {BatchPermitSweeper} from "../src/BatchPermitSweeper.sol";
import {PermitToken} from "./mocks/Tokens.sol";

contract GovernanceTest is TestBase {
    function testConstructorAssignsFinalOwnerAndWorkersWhilePaused() public {
        address[] memory workers = new address[](2);
        workers[0] = alice;
        workers[1] = bob;
        BatchPermitSweeper instance = new BatchPermitSweeper(treasury, worker, workers);
        assertEq(instance.owner(), treasury);
        assertEq(instance.recipient(), worker);
        assertTrue(instance.isOperator(alice));
        assertTrue(instance.isOperator(bob));
        assertFalse(instance.isOperator(address(this)));
        assertTrue(instance.paused());
        assertEq(instance.configVersion(), 1);
        assertFalse(instance.isTokenAllowed(address(token)));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        instance.unpause();
    }

    function testConstructorRejectsZeroOwnerAndRecipient() public {
        vm.expectRevert();
        new BatchPermitSweeper(address(0), treasury, new address[](0));
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.InvalidAddress.selector, address(0)));
        new BatchPermitSweeper(address(this), address(0), new address[](0));
    }

    function testConstructorRejectsDuplicateAndZeroWorkers() public {
        address[] memory workers = new address[](2);
        workers[0] = worker;
        workers[1] = worker;
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.DuplicateOperator.selector, worker));
        new BatchPermitSweeper(address(this), treasury, workers);
        workers[1] = address(0);
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.InvalidAddress.selector, address(0)));
        new BatchPermitSweeper(address(this), treasury, workers);
    }

    function testWorkerCanPauseButCannotUnpause() public {
        vm.prank(worker);
        sweeper.pause();
        assertTrue(sweeper.paused());
        vm.prank(worker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, worker));
        sweeper.unpause();
        sweeper.unpause();
        assertFalse(sweeper.paused());
    }

    function testOutsiderCannotPause() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.NotAuthorized.selector, alice));
        sweeper.pause();
    }

    function testBothSweepEntrypointsCloseWhilePaused() public {
        sweeper.pause();
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        sweeper.batchSweep(address(token), _one(alice), context);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        sweeper.batchSweepWithPermit(address(token), new BatchPermitSweeper.PermitParam[](0), context);
    }

    function testOldContextStaysInvalidAfterPauseAndResume() public {
        BatchPermitSweeper.SweepContext memory old = _context();
        sweeper.pause();
        sweeper.unpause();
        _expectStale(old);
    }

    function testPermissionChangesInvalidateContextsButNoOpsDoNot() public {
        uint256 original = sweeper.configVersion();
        sweeper.setOperator(worker, true);
        sweeper.setTokenAllowed(address(token), true);
        assertEq(sweeper.configVersion(), original);
        BatchPermitSweeper.SweepContext memory old = _context();
        sweeper.setOperator(worker, false);
        sweeper.setOperator(worker, true);
        _expectStale(old);
        old = _context();
        sweeper.setTokenAllowed(address(token), false);
        sweeper.setTokenAllowed(address(token), true);
        _expectStale(old);
    }

    function testRemovedWorkerCannotPause() public {
        sweeper.setOperator(worker, false);
        vm.prank(worker);
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.NotAuthorized.selector, worker));
        sweeper.pause();
    }

    function testWorkerCannotManagePermissionsOrRecipient() public {
        vm.startPrank(worker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, worker));
        sweeper.setOperator(alice, true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, worker));
        sweeper.setTokenAllowed(address(token), false);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, worker));
        sweeper.proposeRecipient(alice);
        vm.stopPrank();
    }

    function testTokenCanBeDisabledAfterCodeDisappears() public {
        vm.etch(address(token), hex"");
        sweeper.setTokenAllowed(address(token), false);
        assertFalse(sweeper.isTokenAllowed(address(token)));
    }

    function testInvalidManagementAddressesRejected() public {
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.InvalidAddress.selector, address(0)));
        sweeper.setOperator(address(0), true);
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.InvalidAddress.selector, address(sweeper)));
        sweeper.setOperator(address(sweeper), true);
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.InvalidToken.selector, alice));
        sweeper.setTokenAllowed(alice, true);
    }

    function testNormalRotationKeepsOldRecipientUntilActivation() public {
        uint256 version = sweeper.configVersion();
        sweeper.proposeRecipient(bob);
        (uint256 id,, uint256 validAfter) = sweeper.pendingRecipientChange();
        assertEq(sweeper.configVersion(), version);
        assertFalse(sweeper.paused());
        _fundAndApprove(alice, 100, 100);
        sweeper.batchSweep(address(token), _one(alice), _context());
        assertEq(token.balanceOf(treasury), 100);
        vm.warp(validAfter);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        sweeper.activateRecipient(id, bob);
        sweeper.pause();
        sweeper.activateRecipient(id, bob);
        assertEq(sweeper.recipient(), bob);
        assertTrue(sweeper.paused());
        (uint256 cleared,,) = sweeper.pendingRecipientChange();
        assertEq(cleared, 0);
    }

    function testRotationRequiresFullTwentyFourHours() public {
        sweeper.proposeRecipient(bob);
        (uint256 id,, uint256 validAfter) = sweeper.pendingRecipientChange();
        sweeper.pause();
        vm.warp(validAfter - 1);
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.RecipientChangeNotReady.selector, validAfter));
        sweeper.activateRecipient(id, bob);
        vm.warp(validAfter);
        sweeper.activateRecipient(id, bob);
        assertEq(sweeper.recipient(), bob);
    }

    function testReplacingProposalResetsDelayAndInvalidatesOldConfirmation() public {
        sweeper.proposeRecipient(bob);
        (uint256 oldId,, uint256 oldAfter) = sweeper.pendingRecipientChange();
        vm.warp(oldAfter);
        sweeper.proposeRecipient(bob);
        (uint256 newId,, uint256 newAfter) = sweeper.pendingRecipientChange();
        assertGt(newId, oldId);
        assertEq(newAfter, oldAfter + 24 hours);
        sweeper.pause();
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.RecipientProposalMismatch.selector, oldId, newId));
        sweeper.activateRecipient(oldId, bob);
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.RecipientChangeNotReady.selector, newAfter));
        sweeper.activateRecipient(newId, bob);
    }

    function testWrongExpectedRecipientAndCancelledProposalRejected() public {
        sweeper.proposeRecipient(bob);
        (uint256 id,, uint256 validAfter) = sweeper.pendingRecipientChange();
        sweeper.pause();
        vm.warp(validAfter);
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.RecipientMismatch.selector, alice, bob));
        sweeper.activateRecipient(id, alice);
        uint256 version = sweeper.configVersion();
        sweeper.cancelRecipientChange(id);
        assertEq(sweeper.configVersion(), version);
        vm.expectRevert(BatchPermitSweeper.NoPendingRecipientChange.selector);
        sweeper.activateRecipient(id, bob);
    }

    function testInvalidRecipientsRejected() public {
        address[3] memory invalid = [address(0), address(sweeper), treasury];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.InvalidAddress.selector, invalid[i]));
            sweeper.proposeRecipient(invalid[i]);
        }
    }

    function testOwnerTransferRequiresAcceptanceAndInvalidatesOldContext() public {
        BatchPermitSweeper.SweepContext memory old = _context();
        sweeper.transferOwnership(bob);
        assertEq(sweeper.owner(), address(this));
        assertEq(sweeper.pendingOwner(), bob);
        assertEq(sweeper.configVersion(), old.expectedConfigVersion);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        sweeper.acceptOwnership();
        vm.prank(bob);
        sweeper.acceptOwnership();
        assertEq(sweeper.owner(), bob);
        assertEq(sweeper.pendingOwner(), address(0));
        assertEq(sweeper.recipient(), treasury);
        assertTrue(sweeper.isOperator(worker));
        assertEq(sweeper.configVersion(), old.expectedConfigVersion + 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        sweeper.setOperator(alice, true);
    }

    function testOwnerTransferCancellationDoesNotRenounce() public {
        sweeper.transferOwnership(bob);
        sweeper.transferOwnership(address(0));
        assertEq(sweeper.owner(), address(this));
        assertEq(sweeper.pendingOwner(), address(0));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        sweeper.acceptOwnership();
    }

    function testRenounceAndSelfTransferRejected() public {
        vm.expectRevert(BatchPermitSweeper.OwnershipRenounceDisabled.selector);
        sweeper.renounceOwnership();
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.InvalidAddress.selector, address(sweeper)));
        sweeper.transferOwnership(address(sweeper));
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.InvalidAddress.selector, address(this)));
        sweeper.transferOwnership(address(this));
    }

    function testOldOwnerRetainsOnlySeparatelyGrantedWorkerRole() public {
        sweeper.setOperator(address(this), true);
        sweeper.transferOwnership(bob);
        vm.prank(bob);
        sweeper.acceptOwnership();
        sweeper.pause();
        assertTrue(sweeper.paused());
        vm.prank(bob);
        sweeper.setOperator(address(this), false);
        vm.prank(bob);
        sweeper.unpause();
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.NotAuthorized.selector, address(this)));
        sweeper.pause();
    }

    function testOwnerHandoverDoesNotResetRecipientProposalDelay() public {
        sweeper.proposeRecipient(alice);
        (uint256 id,, uint256 ready) = sweeper.pendingRecipientChange();
        sweeper.transferOwnership(bob);
        vm.prank(bob);
        sweeper.acceptOwnership();
        vm.prank(worker);
        sweeper.pause();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.RecipientChangeNotReady.selector, ready));
        sweeper.activateRecipient(id, alice);
    }

    function testRecoveryOnlyUsesContractBalanceAndFixedRecipient() public {
        PermitToken other = new PermitToken();
        other.mint(address(sweeper), 100);
        _fundAndApprove(alice, 77, type(uint256).max);
        sweeper.pause();
        sweeper.recoverERC20(address(other), 60, _context());
        assertEq(other.balanceOf(treasury), 60);
        assertEq(other.balanceOf(address(sweeper)), 40);
        assertEq(token.balanceOf(alice), 77);
        assertFalse(sweeper.isTokenAllowed(address(other)));
    }

    function testRecoveryRequiresPauseOwnerAndValidAmount() public {
        token.mint(address(sweeper), 10);
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.expectRevert(Pausable.ExpectedPause.selector);
        sweeper.recoverERC20(address(token), 10, context);
        sweeper.pause();
        context = _context();
        vm.prank(worker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, worker));
        sweeper.recoverERC20(address(token), 10, context);
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.InvalidRecoveryAmount.selector, 0, 10));
        sweeper.recoverERC20(address(token), 0, context);
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.InvalidRecoveryAmount.selector, 11, 10));
        sweeper.recoverERC20(address(token), 11, context);
    }

    function testRecoveryRejectsFeeTokens() public {
        token.mint(address(sweeper), 100);
        token.setMode(PermitToken.Mode.Fee);
        sweeper.pause();
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.ReceivedAmountMismatch.selector, 100, 0, 99));
        sweeper.recoverERC20(address(token), 100, context);
        assertEq(token.balanceOf(address(sweeper)), 100);
    }

    function _expectStale(BatchPermitSweeper.SweepContext memory context) private {
        uint256 current = sweeper.configVersion();
        vm.expectRevert(
            abi.encodeWithSelector(BatchPermitSweeper.ConfigVersionMismatch.selector, context.expectedConfigVersion, current)
        );
        sweeper.batchSweep(address(token), _one(alice), context);
    }
}
