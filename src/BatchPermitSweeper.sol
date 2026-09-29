// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BatchPermitSweeper
/// @notice Atomic, full-balance sweeps from custodial accounts to a timelocked recipient.
/// @dev Allowance is a standing authorization, not a signed instruction for one sweep.
/// Only reviewed, non-rebasing, non-fee-on-transfer tokens should be allowlisted.
contract BatchPermitSweeper is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant RECIPIENT_CHANGE_DELAY = 24 hours;
    address public recipient;
    mapping(address => bool) public isOperator;
    mapping(address => bool) public isTokenAllowed;
    uint256 public configVersion = 1;
    uint256 public recipientChangeNonce;

    struct SweepContext {
        address expectedRecipient;
        uint256 expectedConfigVersion;
        uint256 validUntil;
    }

    struct PermitParam {
        address owner;
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct RecipientChange {
        uint256 proposalId;
        address newRecipient;
        uint256 validAfter;
    }

    RecipientChange public pendingRecipientChange;

    error InvalidAddress(address account);
    error DuplicateOperator(address account);
    error NotAuthorized(address caller);
    error EmptyBatch();
    error InvalidToken(address token);
    error TokenNotAllowed(address token);
    error InvalidSource(address source);
    error SourcesNotStrictlyIncreasing(address previous, address current);
    error ZeroBalance(address source);
    error InsufficientAllowance(address source, uint256 allowance, uint256 required);
    error RecipientMismatch(address expected, address actual);
    error ConfigVersionMismatch(uint256 expected, uint256 actual);
    error BatchExpired(uint256 validUntil);
    error ReceivedAmountMismatch(uint256 expected, uint256 balanceBefore, uint256 balanceAfter);
    error NoPendingRecipientChange();
    error RecipientProposalMismatch(uint256 expected, uint256 actual);
    error RecipientChangeNotReady(uint256 validAfter);
    error OwnershipRenounceDisabled();
    error InvalidRecoveryAmount(uint256 amount, uint256 available);

    event OperatorUpdated(address indexed operator, bool status);
    event TokenAllowedUpdated(address indexed token, bool status);
    event ConfigVersionUpdated(uint256 oldVersion, uint256 newVersion, address indexed actor);
    event RecipientChangeProposed(uint256 indexed proposalId, address indexed newRecipient, uint256 validAfter);
    event RecipientChangeCancelled(uint256 indexed proposalId, address indexed newRecipient);
    event RecipientUpdated(
        address indexed oldRecipient, address indexed newRecipient, uint256 indexed proposalId, uint256 configVersion
    );
    event UserSwept(address indexed token, address indexed from, address indexed recipient, uint256 amount);
    event BatchSwept(
        address indexed token,
        address indexed recipient,
        address indexed operator,
        uint256 totalAmount,
        uint256 totalCount,
        uint256 configVersion
    );
    event ERC20Recovered(
        address indexed token, address indexed recipient, address indexed operator, uint256 amount, uint256 configVersion
    );

    modifier onlyOperatorOrOwner() {
        if (msg.sender != owner() && !isOperator[msg.sender]) revert NotAuthorized(msg.sender);
        _;
    }

    /// @param initialOwner The final administrator, normally a reviewed 2-of-3 multisig.
    /// @param initialRecipient The initial treasury. It must not be this contract.
    /// @param initialWorkers Initial operators. No temporary deployer privileges are created.
    /// @dev Starts paused with an empty token allowlist. Only the owner can enable operations.
    constructor(address initialOwner, address initialRecipient, address[] memory initialWorkers)
        Ownable(initialOwner)
    {
        _checkAddress(initialOwner);
        _checkAddress(initialRecipient);
        recipient = initialRecipient;
        for (uint256 i; i < initialWorkers.length; ++i) {
            address worker = initialWorkers[i];
            _checkAddress(worker);
            if (isOperator[worker]) revert DuplicateOperator(worker);
            isOperator[worker] = true;
            emit OperatorUpdated(worker, true);
        }
        _pause();
    }

    function batchSweep(address token, address[] calldata sources, SweepContext calldata context)
        external
        nonReentrant
        onlyOperatorOrOwner
        whenNotPaused
        returns (uint256 totalAmount)
    {
        address target = _beginSweep(token, sources.length, context);
        address previous;
        for (uint256 i; i < sources.length; ++i) {
            _checkSource(sources[i], previous, target);
            previous = sources[i];
        }
        IERC20 asset = IERC20(token);
        uint256 beforeBalance = asset.balanceOf(target);
        for (uint256 i; i < sources.length; ++i) {
            totalAmount += _sweepOne(asset, sources[i], target);
        }
        _finishSweep(asset, target, beforeBalance, totalAmount, sources.length);
    }

    function batchSweepWithPermit(address token, PermitParam[] calldata items, SweepContext calldata context)
        external
        nonReentrant
        onlyOperatorOrOwner
        whenNotPaused
        returns (uint256 totalAmount)
    {
        address target = _beginSweep(token, items.length, context);
        address previous;
        for (uint256 i; i < items.length; ++i) {
            _checkSource(items[i].owner, previous, target);
            previous = items[i].owner;
        }
        IERC20 asset = IERC20(token);
        uint256 beforeBalance = asset.balanceOf(target);
        for (uint256 i; i < items.length; ++i) {
            _permitIfNeeded(asset, items[i]);
            totalAmount += _sweepOne(asset, items[i].owner, target);
        }
        _finishSweep(asset, target, beforeBalance, totalAmount, items.length);
    }

    function setOperator(address operator, bool status) external nonReentrant onlyOwner {
        _checkAddress(operator);
        if (isOperator[operator] == status) return;
        isOperator[operator] = status;
        _bumpVersion();
        emit OperatorUpdated(operator, status);
    }

    function setTokenAllowed(address token, bool status) external nonReentrant onlyOwner {
        if (status) _checkToken(token);
        if (isTokenAllowed[token] == status) return;
        isTokenAllowed[token] = status;
        _bumpVersion();
        emit TokenAllowedUpdated(token, status);
    }

    function pause() external nonReentrant onlyOperatorOrOwner {
        _pause();
        _bumpVersion();
    }

    function unpause() external nonReentrant onlyOwner {
        _unpause();
        _bumpVersion();
    }

    function proposeRecipient(address newRecipient) external nonReentrant onlyOwner {
        _checkAddress(newRecipient);
        if (newRecipient == recipient) revert InvalidAddress(newRecipient);
        RecipientChange memory old = pendingRecipientChange;
        if (old.proposalId != 0) emit RecipientChangeCancelled(old.proposalId, old.newRecipient);
        uint256 id = ++recipientChangeNonce;
        uint256 validAfter = block.timestamp + RECIPIENT_CHANGE_DELAY;
        pendingRecipientChange = RecipientChange(id, newRecipient, validAfter);
        emit RecipientChangeProposed(id, newRecipient, validAfter);
    }

    function cancelRecipientChange(uint256 proposalId) external nonReentrant onlyOwner {
        RecipientChange memory change = _getProposal(proposalId);
        delete pendingRecipientChange;
        emit RecipientChangeCancelled(change.proposalId, change.newRecipient);
    }

    function activateRecipient(uint256 proposalId, address expectedNewRecipient)
        external
        nonReentrant
        onlyOwner
        whenPaused
    {
        RecipientChange memory change = _getProposal(proposalId);
        if (change.newRecipient != expectedNewRecipient) {
            revert RecipientMismatch(expectedNewRecipient, change.newRecipient);
        }
        if (block.timestamp < change.validAfter) revert RecipientChangeNotReady(change.validAfter);
        address previous = recipient;
        recipient = change.newRecipient;
        delete pendingRecipientChange;
        _bumpVersion();
        emit RecipientUpdated(previous, recipient, proposalId, configVersion);
    }

    /// @dev Zero cancels a pending handover; it never renounces the current ownership.
    function transferOwnership(address newOwner) public override nonReentrant onlyOwner {
        if (newOwner == address(this) || newOwner == owner()) revert InvalidAddress(newOwner);
        super.transferOwnership(newOwner);
    }

    function acceptOwnership() public override nonReentrant {
        super.acceptOwnership();
        _bumpVersion();
    }

    function renounceOwnership() public override onlyOwner {
        revert OwnershipRenounceDisabled();
    }

    /// @notice Recover only the contract's own tokens to the current treasury while paused.
    /// @dev The token need not be allowlisted. Nonstandard tokens may still be unrecoverable.
    function recoverERC20(address token, uint256 amount, SweepContext calldata context)
        external
        nonReentrant
        onlyOwner
        whenPaused
    {
        _checkContext(context);
        _checkToken(token);
        IERC20 asset = IERC20(token);
        uint256 available = asset.balanceOf(address(this));
        if (amount == 0 || amount > available) revert InvalidRecoveryAmount(amount, available);
        address target = recipient;
        uint256 beforeBalance = asset.balanceOf(target);
        asset.safeTransfer(target, amount);
        _checkReceived(asset, target, beforeBalance, amount);
        emit ERC20Recovered(token, target, msg.sender, amount, configVersion);
    }

    function _beginSweep(address token, uint256 count, SweepContext calldata context)
        private
        view
        returns (address)
    {
        _checkContext(context);
        _checkToken(token);
        if (!isTokenAllowed[token]) revert TokenNotAllowed(token);
        if (count == 0) revert EmptyBatch();
        return recipient;
    }

    function _permitIfNeeded(IERC20 asset, PermitParam calldata item) private {
        uint256 balance = asset.balanceOf(item.owner);
        if (balance == 0) revert ZeroBalance(item.owner);
        if (asset.allowance(item.owner, address(this)) >= balance) return;
        // A third party may already have consumed this signature. Check actual allowance below.
        try IERC20Permit(address(asset)).permit(
            item.owner, address(this), item.value, item.deadline, item.v, item.r, item.s
        ) {} catch {}
    }

    function _sweepOne(IERC20 asset, address source, address target) private returns (uint256 balance) {
        // Re-read after any permit call; never silently perform a partial sweep.
        balance = asset.balanceOf(source);
        if (balance == 0) revert ZeroBalance(source);
        uint256 allowed = asset.allowance(source, address(this));
        if (allowed < balance) revert InsufficientAllowance(source, allowed, balance);
        asset.safeTransferFrom(source, target, balance);
        emit UserSwept(address(asset), source, target, balance);
    }

    function _finishSweep(IERC20 asset, address target, uint256 beforeBalance, uint256 amount, uint256 count)
        private
    {
        _checkReceived(asset, target, beforeBalance, amount);
        emit BatchSwept(address(asset), target, msg.sender, amount, count, configVersion);
    }

    function _checkReceived(IERC20 asset, address target, uint256 beforeBalance, uint256 expected) private view {
        uint256 afterBalance = asset.balanceOf(target);
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != expected) {
            revert ReceivedAmountMismatch(expected, beforeBalance, afterBalance);
        }
    }

    function _checkContext(SweepContext calldata context) private view {
        if (context.expectedRecipient != recipient) {
            revert RecipientMismatch(context.expectedRecipient, recipient);
        }
        if (context.expectedConfigVersion != configVersion) {
            revert ConfigVersionMismatch(context.expectedConfigVersion, configVersion);
        }
        if (context.validUntil == 0 || block.timestamp > context.validUntil) revert BatchExpired(context.validUntil);
    }

    function _checkAddress(address account) private view {
        if (account == address(0) || account == address(this)) revert InvalidAddress(account);
    }

    function _checkToken(address token) private view {
        if (token == address(this) || token.code.length == 0) revert InvalidToken(token);
    }

    function _checkSource(address source, address previous, address target) private view {
        if (source == address(0) || source == address(this) || source == target) revert InvalidSource(source);
        if (source <= previous) revert SourcesNotStrictlyIncreasing(previous, source);
    }

    function _getProposal(uint256 proposalId) private view returns (RecipientChange memory change) {
        change = pendingRecipientChange;
        if (change.proposalId == 0) revert NoPendingRecipientChange();
        if (proposalId != change.proposalId) revert RecipientProposalMismatch(proposalId, change.proposalId);
    }

    function _bumpVersion() private {
        uint256 previous = configVersion;
        configVersion = previous + 1;
        emit ConfigVersionUpdated(previous, configVersion, msg.sender);
    }
}
