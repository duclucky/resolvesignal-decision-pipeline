// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Fixed recipient of one exact x402 payment; no buyer-specific signing scheme.
/// @dev A token transfer does not call this contract. The API must attest the payer's
/// canonical receipt before computing/completing. Balance alone is NOT payment proof.
contract ExactPaymentVault is IERC1271, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        Open,
        Completed,
        Refunded
    }

    IERC20 public immutable token;
    address public immutable operator;
    address public immutable treasury;
    address public immutable factory;
    bool public initialized;
    bytes32 public callId;
    bytes32 public termsHash;
    address public payer;
    uint256 public amount;
    uint64 public validBefore;
    uint64 public completeBy;
    Status public status;
    bytes32 public resultCommitment;

    error Unauthorized();
    error InvalidInitialization();
    error NotOpen();
    error CompletionExpired();
    error RefundNotAvailableYet();
    error InsufficientFunding();
    error EmptyResultCommitment();
    error UnexpectedTransferAmount();
    error NotTerminal();
    error NativeDustNotAvailable();
    error NativeDustTransferFailed();

    event Completed(bytes32 indexed callId, bytes32 indexed resultCommitment, uint256 amount);
    event Refunded(bytes32 indexed callId, address indexed payer, uint256 amount);
    event SurplusReturned(bytes32 indexed callId, address indexed payer, uint256 amount);
    event NativeDustReturned(bytes32 indexed callId, address indexed payer, uint256 nativeWei);

    constructor(address token_, address operator_, address treasury_, address factory_) {
        token = IERC20(token_);
        operator = operator_;
        treasury = treasury_;
        factory = factory_;
        // Prevent takeover of the implementation. Clones have separate storage.
        initialized = true;
    }

    function initialize(
        bytes32 callId_,
        address payer_,
        bytes32 termsHash_,
        uint256 amount_,
        uint64 validBefore_,
        uint64 completeBy_
    ) external {
        if (msg.sender != factory) revert Unauthorized();
        if (
            initialized || callId_ == bytes32(0) || termsHash_ == bytes32(0) || payer_ == address(0)
                || payer_ == address(this) || amount_ == 0 || validBefore_ == 0 || validBefore_ >= completeBy_
        ) revert InvalidInitialization();
        initialized = true;
        callId = callId_;
        payer = payer_;
        termsHash = termsHash_;
        amount = amount_;
        validBefore = validBefore_;
        completeBy = completeBy_;
    }

    /// @dev Signatures authorize seller proofs, not arbitrary execution or withdrawals.
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        if (initialized && payer != address(0) && SignatureChecker.isValidSignatureNow(operator, hash, signature)) {
            return IERC1271.isValidSignature.selector;
        }
        return bytes4(0xffffffff);
    }

    /// @notice Operator attests validated HTTP delivery; this is not an onchain quality proof.
    function complete(bytes32 commitment) external nonReentrant {
        if (msg.sender != operator) revert Unauthorized();
        _requireOpen();
        if (block.timestamp >= completeBy) revert CompletionExpired();
        if (commitment == bytes32(0)) revert EmptyResultCommitment();
        if (token.balanceOf(address(this)) < amount) revert InsufficientFunding();
        status = Status.Completed;
        resultCommitment = commitment;
        _sendExact(treasury, amount);
        // Surplus is claimed separately: a blocked payer cannot roll back fee delivery.
        emit Completed(callId, commitment, amount);
    }

    /// @notice Can close an unpaid vault; later deposits remain returnable to its fixed payer.
    function refund() external nonReentrant {
        _requireOpen();
        if (msg.sender != operator && block.timestamp < completeBy) revert RefundNotAvailableYet();
        status = Status.Refunded;
        uint256 balance = token.balanceOf(address(this));
        if (balance != 0) _sendExact(payer, balance);
        emit Refunded(callId, payer, balance);
    }

    /// @notice Anyone may return late/extra USDC, only to the quote's original payer.
    /// @dev Unrelated senders must never transfer here; their identity is not recoverable from balance.
    function returnSurplus() external nonReentrant {
        _requireTerminal();
        _returnSurplus();
    }

    /// @notice Return sub-atomic native USDC only after all ERC-20 USDC has been claimed.
    /// @dev Arc has one shared pool. Never send the whole native balance alongside ERC-20.
    /// A rejecting/blocklisted payer leaves dust here for retry, without undoing the fee/refund.
    function returnNativeDust() external nonReentrant {
        _requireTerminal();
        uint256 dust = address(this).balance;
        if (token.balanceOf(address(this)) != 0 || dust >= 1e12) revert NativeDustNotAvailable();
        if (dust == 0) return;
        uint256 beforeBalance = payer.balance;
        (bool success,) = payable(payer).call{value: dust}("");
        if (!success) revert NativeDustTransferFailed();
        uint256 afterBalance = payer.balance;
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != dust) revert UnexpectedTransferAmount();
        emit NativeDustReturned(callId, payer, dust);
    }

    function _requireTerminal() private view {
        if (!initialized || payer == address(0) || status == Status.Open) revert NotTerminal();
    }

    function _requireOpen() private view {
        if (!initialized || payer == address(0) || status != Status.Open) revert NotOpen();
    }

    function _returnSurplus() private {
        uint256 balance = token.balanceOf(address(this));
        if (balance != 0) {
            _sendExact(payer, balance);
            emit SurplusReturned(callId, payer, balance);
        }
    }

    function _sendExact(address recipient, uint256 value) private {
        uint256 beforeBalance = token.balanceOf(recipient);
        token.safeTransfer(recipient, value);
        uint256 afterBalance = token.balanceOf(recipient);
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != value) revert UnexpectedTransferAmount();
    }

    // Arc native USDC and ERC-20 USDC share a balance. Operator pays tx gas separately.
    receive() external payable {}
}
