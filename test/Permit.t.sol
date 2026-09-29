// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TestBase} from "./TestBase.sol";
import {BatchPermitSweeper} from "../src/BatchPermitSweeper.sol";
import {PermitToken} from "./mocks/Tokens.sol";

contract PermitTest is TestBase {
    function testPermitEstablishesStandingAuthorization() public {
        token.mint(alice, 100);
        BatchPermitSweeper.PermitParam[] memory items =
            _onePermit(_permit(ALICE_KEY, type(uint256).max, block.timestamp + 30 minutes));
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.prank(worker);
        sweeper.batchSweepWithPermit(address(token), items, context);
        assertEq(token.nonces(alice), 1);
        assertEq(token.balanceOf(treasury), 100);
        token.mint(alice, 50);
        vm.prank(worker);
        sweeper.batchSweep(address(token), _one(alice), context);
        assertEq(token.balanceOf(treasury), 150);
        assertEq(token.nonces(alice), 1);
    }

    function testFrontRunPermitDoesNotBlockSweep() public {
        token.mint(alice, 100);
        BatchPermitSweeper.PermitParam memory item = _permit(ALICE_KEY, type(uint256).max, block.timestamp + 30 minutes);
        vm.prank(bob);
        token.permit(item.owner, address(sweeper), item.value, item.deadline, item.v, item.r, item.s);
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.prank(worker);
        sweeper.batchSweepWithPermit(address(token), _onePermit(item), context);
        assertEq(token.nonces(alice), 1);
        assertEq(token.balanceOf(treasury), 100);
    }

    function testUnusedSignatureIsNotConsumed() public {
        _fundAndApprove(alice, 100, type(uint256).max);
        BatchPermitSweeper.PermitParam[] memory items = _onePermit(_permit(ALICE_KEY, 0, block.timestamp + 30 minutes));
        sweeper.batchSweepWithPermit(address(token), items, _context());
        assertEq(token.nonces(alice), 0);
        assertEq(token.allowance(alice, address(sweeper)), type(uint256).max);
    }

    function testInvalidSignatureIgnoredOnlyWithEnoughAllowance() public {
        _fundAndApprove(alice, 100, 100);
        BatchPermitSweeper.PermitParam memory invalid = BatchPermitSweeper.PermitParam(alice, 0, 0, 0, 0, 0);
        sweeper.batchSweepWithPermit(address(token), _onePermit(invalid), _context());
        assertEq(token.balanceOf(treasury), 100);
        token.mint(alice, 10);
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.InsufficientAllowance.selector, alice, 0, 10));
        sweeper.batchSweepWithPermit(address(token), _onePermit(invalid), context);
    }

    function testExpiredPermitCannotCreateAllowance() public {
        token.mint(alice, 100);
        BatchPermitSweeper.PermitParam[] memory items = _onePermit(_permit(ALICE_KEY, 100, block.timestamp - 1));
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.InsufficientAllowance.selector, alice, 0, 100));
        sweeper.batchSweepWithPermit(address(token), items, context);
        assertEq(token.nonces(alice), 0);
    }

    function testWrongOwnerSignatureCannotCreateAllowance() public {
        token.mint(alice, 100);
        BatchPermitSweeper.PermitParam memory item = _permit(BOB_KEY, 100, block.timestamp + 30 minutes);
        item.owner = alice;
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.InsufficientAllowance.selector, alice, 0, 100));
        sweeper.batchSweepWithPermit(address(token), _onePermit(item), context);
    }

    function testFinitePermitInsufficientAfterDepositRollsBackNonce() public {
        token.mint(alice, 100);
        BatchPermitSweeper.PermitParam[] memory items = _onePermit(_permit(ALICE_KEY, 100, block.timestamp + 30 minutes));
        token.mint(alice, 1);
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.InsufficientAllowance.selector, alice, 100, 101));
        sweeper.batchSweepWithPermit(address(token), items, context);
        assertEq(token.nonces(alice), 0);
        assertEq(token.allowance(alice, address(sweeper)), 0);
        assertEq(token.balanceOf(alice), 101);
    }

    function testLaterFailureRollsBackAllPermitsAndTransfers() public {
        token.mint(alice, 100);
        token.mint(bob, 200);
        BatchPermitSweeper.PermitParam[] memory items = new BatchPermitSweeper.PermitParam[](2);
        items[0] = _permit(ALICE_KEY, type(uint256).max, block.timestamp + 30 minutes);
        items[1] = _permit(BOB_KEY, type(uint256).max, block.timestamp + 30 minutes);
        if (items[0].owner > items[1].owner) (items[0], items[1]) = (items[1], items[0]);
        token.setBlocked(items[1].owner, true);
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.expectRevert(abi.encodeWithSelector(PermitToken.Blocked.selector, items[1].owner));
        sweeper.batchSweepWithPermit(address(token), items, context);
        assertEq(token.nonces(alice), 0);
        assertEq(token.nonces(bob), 0);
        assertEq(token.allowance(alice, address(sweeper)), 0);
        assertEq(token.allowance(bob, address(sweeper)), 0);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(bob), 200);
    }

    function testZeroBalanceDoesNotConsumePermit() public {
        BatchPermitSweeper.PermitParam[] memory items =
            _onePermit(_permit(ALICE_KEY, type(uint256).max, block.timestamp + 30 minutes));
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.ZeroBalance.selector, alice));
        sweeper.batchSweepWithPermit(address(token), items, context);
        assertEq(token.nonces(alice), 0);
    }

    function testPermitEntryRejectsUnauthorizedAndEmptyBatch() public {
        BatchPermitSweeper.SweepContext memory context = _context();
        BatchPermitSweeper.PermitParam[] memory empty = new BatchPermitSweeper.PermitParam[](0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.NotAuthorized.selector, alice));
        sweeper.batchSweepWithPermit(address(token), empty, context);
        vm.expectRevert(BatchPermitSweeper.EmptyBatch.selector);
        sweeper.batchSweepWithPermit(address(token), empty, context);
    }

    function testPermitEntryRejectsDuplicateSources() public {
        BatchPermitSweeper.PermitParam[] memory items = new BatchPermitSweeper.PermitParam[](2);
        items[0].owner = alice;
        items[1].owner = alice;
        BatchPermitSweeper.SweepContext memory context = _context();
        vm.expectRevert(abi.encodeWithSelector(BatchPermitSweeper.SourcesNotStrictlyIncreasing.selector, alice, alice));
        sweeper.batchSweepWithPermit(address(token), items, context);
    }
}
