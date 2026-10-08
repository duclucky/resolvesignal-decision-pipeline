// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm, AuditBlocklistUSDC, AuditRevocableOperator} from "./TestSupport.sol";
import {ExactEscrowFactory} from "../src/ExactEscrowFactory.sol";
import {ExactPaymentVault} from "../src/ExactPaymentVault.sol";

interface NativeFixVm {
    function deal(address, uint256) external;
}

contract DustReceiver {
    address public vault;
    bool public rejects;
    bool public reentrySucceeded;

    function configure(address vault_, bool rejects_) external {
        vault = vault_;
        rejects = rejects_;
    }

    receive() external payable {
        require(!rejects, "reject dust");
        (reentrySucceeded,) = vault.call(abi.encodeWithSignature("returnNativeDust()"));
    }
}

contract ExactEscrowRemediationTest {
    address private constant CHEAT = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm private constant vm = Vm(CHEAT);
    NativeFixVm private constant nvm = NativeFixVm(CHEAT);
    address private constant USDC = 0x3600000000000000000000000000000000000000;
    uint256 private constant KEY = 551;
    address private operator;
    address private payer;
    address private treasury;
    AuditBlocklistUSDC private token;
    ExactEscrowFactory private factory;

    function setUp() public {
        vm.chainId(5042);
        vm.warp(1_000_000);
        AuditBlocklistUSDC template = new AuditBlocklistUSDC();
        vm.etch(USDC, address(template).code);
        token = AuditBlocklistUSDC(USDC);
        operator = vm.addr(KEY);
        payer = vm.addr(552);
        treasury = vm.addr(553);
        factory = new ExactEscrowFactory(operator, treasury);
    }

    function _quote() private view returns (ExactEscrowFactory.Quote memory) {
        return ExactEscrowFactory.Quote(
            keccak256("fix-call"),
            payer,
            keccak256("terms"),
            1_000_000,
            uint64(block.timestamp + 300),
            uint64(block.timestamp + 600)
        );
    }

    function _sign(ExactEscrowFactory f, ExactEscrowFactory.Quote memory q) private returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, f.quoteDigest(q));
        return abi.encodePacked(r, s, v);
    }

    function _create() private returns (ExactPaymentVault) {
        ExactEscrowFactory.Quote memory q = _quote();
        return ExactPaymentVault(payable(factory.createVault(q, _sign(factory, q))));
    }

    function testRejectSignedQuoteWithTenYearExpiry() public {
        ExactEscrowFactory.Quote memory q = _quote();
        q.validBefore = uint64(block.timestamp + 3650 days);
        q.completeBy = q.validBefore + 60;
        bytes memory sig = _sign(factory, q);
        vm.expectRevert(ExactEscrowFactory.InvalidQuote.selector);
        factory.createVault(q, sig);
    }

    function testBlockedPayerAndSurplusCannotRollbackFeeCompletion() public {
        ExactPaymentVault vault = _create();
        token.mint(address(vault), 1_000_001);
        token.setBlocked(payer, true);
        vm.prank(operator);
        vault.complete(keccak256("delivered"));
        require(vault.status() == ExactPaymentVault.Status.Completed, "fee terminal");
        require(token.balanceOf(treasury) == 1_000_000 && token.balanceOf(address(vault)) == 1, "surplus stays owed");
        vm.expectRevert();
        vault.returnSurplus();
        require(
            vault.status() == ExactPaymentVault.Status.Completed && token.balanceOf(address(vault)) == 1,
            "failed claim preserves fee"
        );
        token.setBlocked(payer, false);
        vault.returnSurplus();
        require(token.balanceOf(payer) == 1, "original payer can recover after unblock");
    }

    function testTerminalNativeDustCanBeClaimedOnlyToFixedPayer() public {
        ExactPaymentVault vault = _create();
        vm.prank(operator);
        vault.refund();
        nvm.deal(address(vault), 1);
        uint256 beforeBalance = payer.balance;
        (bool ok,) = address(vault).call(abi.encodeWithSignature("returnNativeDust()"));
        require(ok, "native dust claim missing or failed");
        require(address(vault).balance == 0 && payer.balance == beforeBalance + 1, "dust to original payer");
    }

    function testFutureExpiryBoundaryAcceptedAndPlusOneRejected() public {
        ExactEscrowFactory.Quote memory q = _quote();
        factory.createVault(q, _sign(factory, q));
        q.callId = keccak256("too far");
        q.validBefore++;
        q.completeBy++;
        bytes memory sig = _sign(factory, q);
        vm.expectRevert(ExactEscrowFactory.InvalidQuote.selector);
        factory.createVault(q, sig);
    }

    function testUint64MaximumExpiryRejected() public {
        ExactEscrowFactory.Quote memory q = _quote();
        q.validBefore = type(uint64).max - 60;
        q.completeBy = type(uint64).max;
        bytes memory sig = _sign(factory, q);
        vm.expectRevert(ExactEscrowFactory.InvalidQuote.selector);
        factory.createVault(q, sig);
    }

    function testExpiredQuoteRecoveryStillWorks() public {
        ExactEscrowFactory.Quote memory q = _quote();
        bytes memory sig = _sign(factory, q);
        address predicted = factory.predictVault(q);
        token.mint(predicted, q.amount);
        vm.warp(q.completeBy + 1000);
        ExactPaymentVault vault = ExactPaymentVault(payable(factory.createVault(q, sig)));
        vault.refund();
        require(token.balanceOf(payer) == q.amount, "stale recovery");
    }

    function testExistingVaultLookupSurvivesSignatureRevocationAndExpiry() public {
        AuditRevocableOperator smart = new AuditRevocableOperator(operator);
        ExactEscrowFactory f = new ExactEscrowFactory(address(smart), treasury);
        ExactEscrowFactory.Quote memory q = _quote();
        bytes memory sig = _sign(f, q);
        address first = f.createVault(q, sig);
        smart.revoke();
        vm.warp(q.completeBy + 1);
        require(f.createVault(q, hex"") == first, "bound lookup independent of signer");
        q.amount++;
        vm.expectRevert(ExactEscrowFactory.CallAlreadyUsed.selector);
        f.createVault(q, hex"");
    }

    function testPermissionlessRefundAlwaysWithinThirtyFiveMinutesForFreshQuote() public {
        ExactEscrowFactory.Quote memory q = _quote();
        q.completeBy = q.validBefore + 1800;
        ExactPaymentVault vault = ExactPaymentVault(payable(factory.createVault(q, _sign(factory, q))));
        token.mint(address(vault), q.amount);
        vm.warp(1_000_000 + 35 minutes);
        vault.refund();
        require(token.balanceOf(payer) == q.amount, "absolute max refund wait");
    }

    function testNativeDustNotClaimableFromOpenVault() public {
        ExactPaymentVault vault = _create();
        nvm.deal(address(vault), 1);
        vm.expectRevert(ExactPaymentVault.NotTerminal.selector);
        vault.returnNativeDust();
    }

    function testNativeDustNeverMovesWholeUSDC() public {
        ExactPaymentVault vault = _create();
        vm.prank(operator);
        vault.refund();
        nvm.deal(address(vault), 1e12);
        vm.expectRevert(ExactPaymentVault.NativeDustNotAvailable.selector);
        vault.returnNativeDust();
        require(address(vault).balance == 1e12, "no whole pool withdrawal");
    }

    function testNativeDustRequiresERC20SurplusClaimFirst() public {
        ExactPaymentVault vault = _create();
        vm.prank(operator);
        vault.refund();
        token.mint(address(vault), 1);
        nvm.deal(address(vault), 1);
        vm.expectRevert(ExactPaymentVault.NativeDustNotAvailable.selector);
        vault.returnNativeDust();
        vault.returnSurplus();
        vault.returnNativeDust();
        require(token.balanceOf(payer) == 1 && address(vault).balance == 0, "separate obligations");
    }

    function testNativeDustReceiverFailureRetainsTerminalStateAndAllowsRetry() public {
        DustReceiver receiver = new DustReceiver();
        ExactEscrowFactory.Quote memory q = _quote();
        q.payer = address(receiver);
        ExactPaymentVault vault = ExactPaymentVault(payable(factory.createVault(q, _sign(factory, q))));
        vm.prank(operator);
        vault.refund();
        receiver.configure(address(vault), true);
        nvm.deal(address(vault), 1);
        vm.expectRevert(ExactPaymentVault.NativeDustTransferFailed.selector);
        vault.returnNativeDust();
        require(
            vault.status() == ExactPaymentVault.Status.Refunded && address(vault).balance == 1,
            "claim pending, refund retained"
        );
        receiver.configure(address(vault), false);
        vault.returnNativeDust();
        require(
            !receiver.reentrySucceeded() && address(receiver).balance == 1 && address(vault).balance == 0,
            "retry exact, no reentry"
        );
        vault.returnNativeDust();
        require(address(receiver).balance == 1, "no double dust claim");
    }

    function testNativeDustImplementationRemainsLocked() public {
        ExactPaymentVault implementation = ExactPaymentVault(payable(factory.implementation()));
        nvm.deal(address(implementation), 1);
        vm.expectRevert(ExactPaymentVault.NotTerminal.selector);
        implementation.returnNativeDust();
    }

    function testFuzzDustConservation(uint64 raw) public {
        uint256 dust = uint256(raw) % 1e12;
        ExactPaymentVault vault = _create();
        vm.prank(operator);
        vault.refund();
        nvm.deal(address(vault), dust);
        uint256 beforeBalance = payer.balance;
        vault.returnNativeDust();
        require(payer.balance == beforeBalance + dust && address(vault).balance == 0, "dust conserved");
    }
}
