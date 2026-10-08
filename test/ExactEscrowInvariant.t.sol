// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockUSDC, Vm} from "./TestSupport.sol";
import {ExactEscrowFactory} from "../src/ExactEscrowFactory.sol";
import {ExactPaymentVault} from "../src/ExactPaymentVault.sol";

/// @dev Stateful V3 lifecycle, multiple payers, partial/late funding and retries.
contract ExactVaultHandler {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant KEY = 4711;
    ExactEscrowFactory public immutable factory;
    MockUSDC public immutable token;
    address public immutable operator;
    address public immutable treasury;
    ExactPaymentVault[] public vaults;
    uint256 public funded;
    uint256 public completed;
    uint256 public returned;
    mapping(address => uint256) public payerReturns;
    mapping(address => uint256) public vaultCompletions;

    constructor(ExactEscrowFactory f, MockUSDC t, address op, address tr) {
        factory = f;
        token = t;
        operator = op;
        treasury = tr;
    }

    function create(uint96 seed) public {
        if (vaults.length >= 12) return;
        ExactEscrowFactory.Quote memory q = ExactEscrowFactory.Quote(
            bytes32(vaults.length + 1),
            address(uint160(0xA001 + seed % 3)),
            keccak256("invariant terms"),
            1 + uint256(seed) % 1000000,
            uint64(block.timestamp + 60),
            uint64(block.timestamp + 180)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, factory.quoteDigest(q));
        address vault = factory.createVault(q, abi.encodePacked(r, s, v));
        vaults.push(ExactPaymentVault(payable(vault)));
    }

    function deposit(uint256 index, uint96 amount) external {
        if (vaults.length == 0) create(amount);
        uint256 value = 1 + uint256(amount) % 2000000;
        token.mint(address(vaults[index % vaults.length]), value);
        funded += value;
    }

    function resolve(uint256 index, bool success) external {
        if (vaults.length == 0) return;
        ExactPaymentVault vault = vaults[index % vaults.length];
        if (vault.status() != ExactPaymentVault.Status.Open) return;
        uint256 beforeBalance = token.balanceOf(address(vault));
        if (success && block.timestamp < vault.completeBy() && beforeBalance >= vault.amount()) {
            vm.prank(operator);
            vault.complete(keccak256(abi.encode(index, "result")));
            completed += vault.amount();
            vaultCompletions[address(vault)] += vault.amount();
        } else {
            if (block.timestamp < vault.completeBy()) vm.prank(operator);
            vault.refund();
            returned += beforeBalance;
            payerReturns[vault.payer()] += beforeBalance;
        }
    }

    function claimLate(uint256 index) external {
        if (vaults.length == 0) return;
        ExactPaymentVault vault = vaults[index % vaults.length];
        if (vault.status() == ExactPaymentVault.Status.Open) return;
        uint256 balance = token.balanceOf(address(vault));
        vault.returnSurplus();
        returned += balance;
        payerReturns[vault.payer()] += balance;
    }

    function advance(uint16 seconds_) external {
        vm.warp(block.timestamp + seconds_ % 300);
    }

    function attemptUnauthorizedOrRepeated(uint256 index) external {
        if (vaults.length == 0) return;
        ExactPaymentVault vault = vaults[index % vaults.length];
        // Handler never has operator privileges. Terminal transitions never repeat.
        (bool completeOk,) = address(vault).call(abi.encodeCall(vault.complete, (keccak256("attacker"))));
        require(!completeOk, "unauthorized_complete");
        if (vault.status() != ExactPaymentVault.Status.Open || block.timestamp < vault.completeBy()) {
            (bool refundOk,) = address(vault).call(abi.encodeCall(vault.refund, ()));
            require(!refundOk, "unauthorized_or_repeated_refund");
        }
    }

    function assertConservation() external view {
        uint256 held;
        for (uint256 i; i < vaults.length; i++) {
            ExactPaymentVault v = vaults[i];
            held += token.balanceOf(address(v));
            require(factory.vaults(v.callId()) == address(v), "call_binding");
            require(v.treasury() == treasury && v.operator() == operator, "fixed_roles");
            require(
                v.payer() == address(0xA001) || v.payer() == address(0xA002) || v.payer() == address(0xA003),
                "fixed_payer"
            );
            require(
                vaultCompletions[address(v)] == (v.status() == ExactPaymentVault.Status.Completed ? v.amount() : 0),
                "one_completion"
            );
            for (uint256 j; j < i; j++) {
                require(address(v) != address(vaults[j]), "vault_isolation");
            }
        }
        require(funded == held + completed + returned, "conservation");
        require(token.balanceOf(treasury) == completed, "treasury_only_completed");
        for (uint160 p = 0xA001; p <= 0xA003; p++) {
            require(token.balanceOf(address(p)) == payerReturns[address(p)], "fixed_refunds");
        }
    }
}

contract ExactEscrowInvariantTest {
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    struct FuzzArtifactSelector {
        string artifact;
        bytes4[] selectors;
    }

    struct FuzzInterface {
        address addr;
        string[] artifacts;
    }
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    ExactVaultHandler handler;

    function setUp() public {
        vm.chainId(5042);
        vm.warp(1000000);
        MockUSDC template = new MockUSDC();
        address usdc = 0x3600000000000000000000000000000000000000;
        vm.etch(usdc, address(template).code);
        address operator = vm.addr(4711);
        ExactEscrowFactory factory = new ExactEscrowFactory(operator, address(0xB001));
        handler = new ExactVaultHandler(factory, MockUSDC(usdc), operator, address(0xB001));
        handler.create(1);
    }

    function targetContracts() external view returns (address[] memory a) {
        a = new address[](1);
        a[0] = address(handler);
    }

    function targetSelectors() external view returns (FuzzSelector[] memory t) {
        bytes4[] memory s = new bytes4[](6);
        s[0] = handler.create.selector;
        s[1] = handler.deposit.selector;
        s[2] = handler.resolve.selector;
        s[3] = handler.claimLate.selector;
        s[4] = handler.advance.selector;
        s[5] = handler.attemptUnauthorizedOrRepeated.selector;
        t = new FuzzSelector[](1);
        t[0] = FuzzSelector(address(handler), s);
    }

    // Explicit empty hooks keep the invariant scope auditable across Forge versions.
    function targetArtifactSelectors() external pure returns (FuzzArtifactSelector[] memory) {
        return new FuzzArtifactSelector[](0);
    }

    function targetArtifacts() external pure returns (string[] memory) {
        return new string[](0);
    }

    function excludeArtifacts() external pure returns (string[] memory) {
        return new string[](0);
    }

    function targetSenders() external pure returns (address[] memory) {
        return new address[](0);
    }

    function excludeSenders() external pure returns (address[] memory) {
        return new address[](0);
    }

    function excludeContracts() external pure returns (address[] memory) {
        return new address[](0);
    }

    function targetInterfaces() external pure returns (FuzzInterface[] memory) {
        return new FuzzInterface[](0);
    }

    function excludeSelectors() external pure returns (FuzzSelector[] memory) {
        return new FuzzSelector[](0);
    }

    function invariantV3MoneyAndRecipientsRemainBound() public view {
        handler.assertConservation();
    }
}
