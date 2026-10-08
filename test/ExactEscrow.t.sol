// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockUSDC, Vm} from "./TestSupport.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ExactEscrowFactory} from "../src/ExactEscrowFactory.sol";
import {ExactPaymentVault} from "../src/ExactPaymentVault.sol";

contract ExactMockUSDC is MockUSDC {
    bytes32 private constant TRANSFER_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    function transferDigest(address from, address to, uint256 value, uint256 after_, uint256 before_, bytes32 nonce)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(TRANSFER_TYPEHASH, from, to, value, after_, before_, nonce)));
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 after_,
        uint256 before_,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(block.timestamp > after_ && block.timestamp < before_, "authorization_time");
        require(!authorizationState[from][nonce], "nonce_used");
        require(ECDSA.recover(transferDigest(from, to, value, after_, before_, nonce), v, r, s) == from, "signature");
        authorizationState[from][nonce] = true;
        _transfer(from, to, value);
        emit AuthorizationUsed(from, nonce);
    }
}

contract ExactMockOperator is IERC1271 {
    address private immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        return ECDSA.recover(hash, signature) == signer ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}

contract ExactEscrowTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant OPERATOR_KEY = 701;
    uint256 private constant PAYER_KEY = 702;
    address private constant USDC = 0x3600000000000000000000000000000000000000;
    ExactMockUSDC private token;
    ExactEscrowFactory private factory;
    ExactEscrowFactory.Quote private q;
    address private operator;
    address private payer;
    address private treasury;

    function setUp() public {
        vm.chainId(5042);
        vm.warp(1_000_000);
        ExactMockUSDC template = new ExactMockUSDC();
        vm.etch(USDC, address(template).code);
        token = ExactMockUSDC(USDC);
        operator = vm.addr(OPERATOR_KEY);
        payer = vm.addr(PAYER_KEY);
        treasury = vm.addr(703);
        factory = new ExactEscrowFactory(operator, treasury);
        q = ExactEscrowFactory.Quote(keccak256("call-1"), payer, keccak256("terms"), 1_000_000, 1_000_300, 1_000_600);
        token.mint(payer, 10_000_000);
    }

    function _signature(bytes32 digest, uint256 key) private returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _create() private returns (ExactPaymentVault) {
        return ExactPaymentVault(payable(factory.createVault(q, _signature(factory.quoteDigest(q), OPERATOR_KEY))));
    }

    function _deposit(address to, uint256 value) private {
        vm.prank(payer);
        token.transfer(to, value);
    }

    function _complete(ExactPaymentVault vault) private {
        vm.prank(operator);
        vault.complete(keccak256("validated-result"));
    }

    function _refund(ExactPaymentVault vault) private {
        vm.prank(operator);
        vault.refund();
    }

    function testExactAuthorizationToPredictedAddressBeforeDeployment() public {
        address predicted = factory.predictVault(q);
        bytes32 nonce = keccak256("client-generated-random-nonce");
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(PAYER_KEY, token.transferDigest(payer, predicted, q.amount, 0, q.validBefore, nonce));
        // Any relayer can consume the standard authorization; receiver code is not invoked.
        token.transferWithAuthorization(payer, predicted, q.amount, 0, q.validBefore, nonce, v, r, s);
        require(predicted.code.length == 0 && token.balanceOf(predicted) == q.amount, "counterfactual payment");
        ExactPaymentVault vault = _create();
        require(address(vault) == predicted && vault.payer() == payer, "binding");
        _complete(vault);
        require(token.balanceOf(treasury) == q.amount && token.balanceOf(predicted) == 0, "exact payout");
        vm.expectRevert();
        token.transferWithAuthorization(payer, predicted, q.amount, 0, q.validBefore, nonce, v, r, s);
    }

    function testInvalidBuyerSignatureCannotTransfer() public {
        address predicted = factory.predictVault(q);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(999, token.transferDigest(payer, predicted, q.amount, 0, q.validBefore, bytes32(0)));
        vm.expectRevert();
        token.transferWithAuthorization(payer, predicted, q.amount, 0, q.validBefore, bytes32(0), v, r, s);
        require(token.balanceOf(predicted) == 0, "no charge");
    }

    function testFullRefundToOriginalPayer() public {
        ExactPaymentVault vault = _create();
        _deposit(address(vault), q.amount);
        _refund(vault);
        require(token.balanceOf(payer) == 10_000_000 && token.balanceOf(treasury) == 0, "full refund");
        require(vault.status() == ExactPaymentVault.Status.Refunded, "terminal");
    }

    function testOnlyOperatorMayRefundEarly() public {
        ExactPaymentVault vault = _create();
        _deposit(address(vault), q.amount);
        vm.prank(payer);
        vm.expectRevert(ExactPaymentVault.RefundNotAvailableYet.selector);
        vault.refund();
    }

    function testAnyoneMayRefundAtDeadline() public {
        ExactPaymentVault vault = _create();
        _deposit(address(vault), q.amount);
        vm.warp(q.completeBy);
        vault.refund();
        require(token.balanceOf(payer) == 10_000_000, "permissionless recovery");
    }

    function testCompleteForbiddenAtDeadline() public {
        ExactPaymentVault vault = _create();
        _deposit(address(vault), q.amount);
        vm.warp(q.completeBy);
        vm.prank(operator);
        vm.expectRevert(ExactPaymentVault.CompletionExpired.selector);
        vault.complete(keccak256("result"));
    }

    function testOnlyOperatorMayComplete() public {
        ExactPaymentVault vault = _create();
        _deposit(address(vault), q.amount);
        vm.expectRevert(ExactPaymentVault.Unauthorized.selector);
        vault.complete(keccak256("result"));
    }

    function testInsufficientBalanceCannotComplete() public {
        ExactPaymentVault vault = _create();
        _deposit(address(vault), q.amount - 1);
        vm.prank(operator);
        vm.expectRevert(ExactPaymentVault.InsufficientFunding.selector);
        vault.complete(keccak256("result"));
    }

    function testEmptyResultCannotComplete() public {
        ExactPaymentVault vault = _create();
        _deposit(address(vault), q.amount);
        vm.prank(operator);
        vm.expectRevert(ExactPaymentVault.EmptyResultCommitment.selector);
        vault.complete(bytes32(0));
    }

    function testTerminalCannotCompleteOrRefundAgain() public {
        ExactPaymentVault vault = _create();
        _deposit(address(vault), q.amount);
        _complete(vault);
        vm.prank(operator);
        vm.expectRevert(ExactPaymentVault.NotOpen.selector);
        vault.complete(keccak256("second"));
        vm.prank(operator);
        vm.expectRevert(ExactPaymentVault.NotOpen.selector);
        vault.refund();
    }

    function testRefundedCannotComplete() public {
        ExactPaymentVault vault = _create();
        _deposit(address(vault), q.amount);
        _refund(vault);
        vm.prank(operator);
        vm.expectRevert(ExactPaymentVault.NotOpen.selector);
        vault.complete(keccak256("second"));
    }

    function testCompletionLeavesExcessClaimableByPayer() public {
        ExactPaymentVault vault = _create();
        _deposit(address(vault), q.amount + 12_345);
        _complete(vault);
        require(token.balanceOf(address(vault)) == 12_345, "surplus obligation stays separate");
        vault.returnSurplus();
        require(token.balanceOf(treasury) == q.amount && token.balanceOf(payer) == 9_000_000, "fee only");
    }

    function testLatePaymentAfterRefundRemainsRecoverable() public {
        ExactPaymentVault vault = _create();
        _refund(vault);
        _deposit(address(vault), q.amount);
        vault.returnSurplus();
        vault.returnSurplus();
        require(token.balanceOf(payer) == 10_000_000 && token.balanceOf(address(vault)) == 0, "late refund");
    }

    function testLatePaymentAfterCompleteCannotChargeTwice() public {
        ExactPaymentVault vault = _create();
        _deposit(address(vault), q.amount);
        _complete(vault);
        _deposit(address(vault), q.amount);
        vault.returnSurplus();
        require(token.balanceOf(treasury) == q.amount && token.balanceOf(payer) == 9_000_000, "once");
    }

    function testOpenVaultCannotSweep() public {
        ExactPaymentVault vault = _create();
        _deposit(address(vault), q.amount);
        vm.expectRevert(ExactPaymentVault.NotTerminal.selector);
        vault.returnSurplus();
    }

    function testExpiredCounterfactualPaymentCanDeployAndRefund() public {
        address predicted = factory.predictVault(q);
        _deposit(predicted, q.amount);
        vm.warp(q.completeBy + 1);
        ExactPaymentVault vault = _create();
        vault.refund();
        require(token.balanceOf(payer) == 10_000_000, "no trapped counterfactual funds");
    }

    function testCreateRetryIsIdempotent() public {
        ExactPaymentVault first = _create();
        require(address(_create()) == address(first), "one vault");
    }

    function testSameCallCannotCreateAnotherQuote() public {
        _create();
        q.amount++;
        bytes memory sig = _signature(factory.quoteDigest(q), OPERATOR_KEY);
        vm.expectRevert(ExactEscrowFactory.CallAlreadyUsed.selector);
        factory.createVault(q, sig);
    }

    function testTamperedQuoteRejected() public {
        bytes memory sig = _signature(factory.quoteDigest(q), OPERATOR_KEY);
        q.payer = vm.addr(999);
        vm.expectRevert(ExactEscrowFactory.InvalidQuoteSignature.selector);
        factory.createVault(q, sig);
    }

    function testCrossFactoryReplayRejected() public {
        bytes memory sig = _signature(factory.quoteDigest(q), OPERATOR_KEY);
        ExactEscrowFactory other = new ExactEscrowFactory(operator, treasury);
        vm.expectRevert(ExactEscrowFactory.InvalidQuoteSignature.selector);
        other.createVault(q, sig);
    }

    function testCrossChainReplayRejected() public {
        bytes memory sig = _signature(factory.quoteDigest(q), OPERATOR_KEY);
        vm.chainId(5042002);
        vm.expectRevert(ExactEscrowFactory.InvalidQuoteSignature.selector);
        factory.createVault(q, sig);
    }

    function testInvalidWindowRejected() public {
        q.completeBy = q.validBefore;
        bytes memory sig = _signature(factory.quoteDigest(q), OPERATOR_KEY);
        vm.expectRevert(ExactEscrowFactory.InvalidQuote.selector);
        factory.createVault(q, sig);
    }

    function testExcessiveWindowRejected() public {
        q.completeBy = q.validBefore + 1801;
        bytes memory sig = _signature(factory.quoteDigest(q), OPERATOR_KEY);
        vm.expectRevert(ExactEscrowFactory.InvalidQuote.selector);
        factory.createVault(q, sig);
    }

    function testImplementationCannotBeInitialized() public {
        ExactPaymentVault implementation = ExactPaymentVault(payable(factory.implementation()));
        vm.prank(address(factory));
        vm.expectRevert(ExactPaymentVault.InvalidInitialization.selector);
        implementation.initialize(q.callId, payer, q.termsHash, q.amount, q.validBefore, q.completeBy);
    }

    function testVaultCannotBeReinitialized() public {
        ExactPaymentVault vault = _create();
        vm.prank(address(factory));
        vm.expectRevert(ExactPaymentVault.InvalidInitialization.selector);
        vault.initialize(q.callId, payer, q.termsHash, q.amount, q.validBefore, q.completeBy);
    }

    function testPublicCannotInitialize() public {
        ExactPaymentVault vault = _create();
        vm.expectRevert(ExactPaymentVault.Unauthorized.selector);
        vault.initialize(q.callId, payer, q.termsHash, q.amount, q.validBefore, q.completeBy);
    }

    function testSellerProofAcceptsOnlyOperatorSignature() public {
        ExactPaymentVault vault = _create();
        bytes32 hash = keccak256("Circle proof EIP712 digest");
        require(
            vault.isValidSignature(hash, _signature(hash, OPERATOR_KEY)) == IERC1271.isValidSignature.selector, "proof"
        );
        require(vault.isValidSignature(hash, _signature(hash, PAYER_KEY)) == bytes4(0xffffffff), "wrong signer");
        require(vault.isValidSignature(hash, hex"00") == bytes4(0xffffffff), "malformed");
    }

    function testContractOperatorQuoteAndProof() public {
        ExactMockOperator smart = new ExactMockOperator(operator);
        ExactEscrowFactory other = new ExactEscrowFactory(address(smart), treasury);
        bytes memory quoteSig = _signature(other.quoteDigest(q), OPERATOR_KEY);
        ExactPaymentVault vault = ExactPaymentVault(payable(other.createVault(q, quoteSig)));
        bytes32 hash = keccak256("seller request");
        require(
            vault.isValidSignature(hash, _signature(hash, OPERATOR_KEY)) == IERC1271.isValidSignature.selector,
            "nested proof"
        );
        _deposit(address(vault), q.amount);
        vm.prank(address(smart));
        vault.complete(keccak256("result"));
        require(token.balanceOf(treasury) == q.amount, "SCA execute");
    }

    function testTokenFailurePreservesRefundObligation() public {
        ExactPaymentVault vault = _create();
        _deposit(address(vault), q.amount);
        token.setRejectTransfers(true);
        vm.prank(operator);
        vm.expectRevert();
        vault.refund();
        require(
            vault.status() == ExactPaymentVault.Status.Open && token.balanceOf(address(vault)) == q.amount, "pending"
        );
        token.setRejectTransfers(false);
        _refund(vault);
    }

    function testShortCreditCannotReportCompleted() public {
        ExactPaymentVault vault = _create();
        _deposit(address(vault), q.amount);
        token.setShortTransfer(true);
        vm.prank(operator);
        vm.expectRevert(ExactPaymentVault.UnexpectedTransferAmount.selector);
        vault.complete(keccak256("result"));
        require(vault.status() == ExactPaymentVault.Status.Open && token.balanceOf(treasury) == 0, "atomic rollback");
    }

    function testShortCreditCannotReportRefunded() public {
        ExactPaymentVault vault = _create();
        _deposit(address(vault), q.amount);
        token.setShortTransfer(true);
        vm.prank(operator);
        vm.expectRevert(ExactPaymentVault.UnexpectedTransferAmount.selector);
        vault.refund();
        require(vault.status() == ExactPaymentVault.Status.Open, "atomic rollback");
    }

    function testReentryCannotDrain() public {
        ExactPaymentVault vault = _create();
        _deposit(address(vault), q.amount);
        token.setHook(address(vault), abi.encodeCall(vault.returnSurplus, ()));
        _complete(vault);
        require(!token.hookSucceeded() && token.balanceOf(treasury) == q.amount, "reentry blocked");
    }

    function testTwoCallsNeverShareFunds() public {
        ExactPaymentVault first = _create();
        q.callId = keccak256("call-2");
        q.payer = vm.addr(704);
        ExactPaymentVault second = _create();
        _deposit(address(first), 1_000_000);
        token.mint(address(second), 2_000_000);
        _complete(first);
        _refund(second);
        require(address(first) != address(second) && token.balanceOf(q.payer) == 2_000_000, "isolated payer");
        require(token.balanceOf(treasury) == 1_000_000, "isolated fee");
    }

    function testWrongChainCannotDeploy() public {
        vm.chainId(1);
        vm.expectRevert(ExactEscrowFactory.WrongChain.selector);
        new ExactEscrowFactory(operator, treasury);
    }

    function testZeroConfigurationRejected() public {
        vm.expectRevert(ExactEscrowFactory.InvalidConfiguration.selector);
        new ExactEscrowFactory(address(0), treasury);
    }

    function testFuzzConservationOnCompletion(uint64 raw) public {
        uint256 surplus = uint256(raw) % 5_000_000;
        ExactPaymentVault vault = _create();
        _deposit(address(vault), q.amount + surplus);
        _complete(vault);
        vault.returnSurplus();
        require(token.balanceOf(treasury) == q.amount && token.balanceOf(payer) == 9_000_000, "conserved");
        require(token.balanceOf(address(vault)) == 0, "empty vault");
    }

    function testFuzzConservationOnRefund(uint64 raw) public {
        uint256 value = uint256(raw) % 10_000_001;
        ExactPaymentVault vault = _create();
        _deposit(address(vault), value);
        _refund(vault);
        require(token.balanceOf(payer) == 10_000_000 && token.balanceOf(treasury) == 0, "conserved");
    }
}
