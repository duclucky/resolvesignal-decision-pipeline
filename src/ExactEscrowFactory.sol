// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ExactPaymentVault} from "./ExactPaymentVault.sol";

/// @notice Creates one deterministic, non-upgradeable exact-payment vault per signed call.
contract ExactEscrowFactory is EIP712 {
    struct Quote {
        bytes32 callId;
        address payer;
        bytes32 termsHash;
        uint256 amount;
        uint64 validBefore;
        uint64 completeBy;
    }

    address public constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "Quote(bytes32 callId,address payer,bytes32 termsHash,uint256 amount,uint64 validBefore,uint64 completeBy)"
    );
    uint256 public constant MAX_DELIVERY_WINDOW = 30 minutes;
    uint256 public constant MAX_QUOTE_LIFETIME = 5 minutes;
    address public immutable token;
    address public immutable operator;
    address public immutable treasury;
    address public immutable implementation;
    mapping(bytes32 => address) public vaults;
    mapping(bytes32 => bytes32) public callQuoteDigests;

    error WrongChain();
    error InvalidConfiguration();
    error InvalidQuote();
    error InvalidQuoteSignature();
    error CallAlreadyUsed();

    event VaultCreated(bytes32 indexed callId, address indexed vault, address indexed payer, bytes32 quoteDigest);

    constructor(address operator_, address treasury_) EIP712("ExactEscrowFactory", "3") {
        if (block.chainid != 5042 && block.chainid != 5042002) revert WrongChain();
        if (
            operator_ == address(0) || treasury_ == address(0) || operator_ == address(this)
                || treasury_ == address(this) || operator_ == ARC_USDC || treasury_ == ARC_USDC
                || IERC20Metadata(ARC_USDC).decimals() != 6
        ) revert InvalidConfiguration();
        token = ARC_USDC;
        operator = operator_;
        treasury = treasury_;
        implementation = address(new ExactPaymentVault(ARC_USDC, operator_, treasury_, address(this)));
    }

    function quoteDigest(Quote calldata q) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(QUOTE_TYPEHASH, q.callId, q.payer, q.termsHash, q.amount, q.validBefore, q.completeBy))
        );
    }

    function predictVault(Quote calldata q) public view returns (address) {
        return Clones.predictDeterministicAddress(implementation, quoteDigest(q), address(this));
    }

    /// @dev Expired quotes may still deploy: counterfactual funds must remain refundable.
    /// Admission, fresh authorization and payment-time checks belong to the API.
    function createVault(Quote calldata q, bytes calldata quoteSignature) external returns (address vault) {
        bytes32 digest = quoteDigest(q);
        vault = vaults[q.callId];
        if (vault != address(0)) {
            if (callQuoteDigests[q.callId] != digest) revert CallAlreadyUsed();
            // Public lookup of an existing, bound vault survives expiry/key rotation.
            return vault;
        }
        if (
            q.callId == bytes32(0) || q.termsHash == bytes32(0) || q.payer == address(0) || q.amount == 0
                || q.validBefore == 0 || q.validBefore >= q.completeBy
                || uint256(q.completeBy) - q.validBefore > MAX_DELIVERY_WINDOW
                || q.validBefore > block.timestamp + MAX_QUOTE_LIFETIME
        ) revert InvalidQuote();
        if (!SignatureChecker.isValidSignatureNow(operator, digest, quoteSignature)) revert InvalidQuoteSignature();
        vault = Clones.cloneDeterministic(implementation, digest);
        vaults[q.callId] = vault;
        callQuoteDigests[q.callId] = digest;
        ExactPaymentVault(payable(vault))
            .initialize(q.callId, q.payer, q.termsHash, q.amount, q.validBefore, q.completeBy);
        emit VaultCreated(q.callId, vault, q.payer, digest);
    }
}
