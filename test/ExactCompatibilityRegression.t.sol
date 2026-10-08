// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockUSDC, Vm} from "./TestSupport.sol";
import {ExactEscrowFactory} from "../src/ExactEscrowFactory.sol";
import {ExactPaymentVault} from "../src/ExactPaymentVault.sol";

/// @dev Regression: standard ERC-20 delivery must be usable without receive authorization.
contract ExactCompatibilityRegression {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function testVanillaTransferCanCompletePaidCall() public {
        vm.chainId(5042);
        MockUSDC template = new MockUSDC();
        address tokenAddress = 0x3600000000000000000000000000000000000000;
        vm.etch(tokenAddress, address(template).code);
        MockUSDC token = MockUSDC(tokenAddress);
        address payer = vm.addr(901);
        address treasury = vm.addr(902);
        address operator = vm.addr(903);
        ExactEscrowFactory factory = new ExactEscrowFactory(operator, treasury);
        ExactEscrowFactory.Quote memory q = ExactEscrowFactory.Quote(
            keccak256("exact-call"),
            payer,
            keccak256("terms"),
            1_000_000,
            uint64(block.timestamp + 300),
            uint64(block.timestamp + 600)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(903, factory.quoteDigest(q));
        ExactPaymentVault escrow = ExactPaymentVault(payable(factory.createVault(q, abi.encodePacked(r, s, v))));
        token.mint(payer, 1_000_000);
        vm.prank(payer);
        token.transfer(address(escrow), 1_000_000);
        vm.prank(operator);
        escrow.complete(keccak256("validated-result"));
        require(token.balanceOf(treasury) == 1_000_000, "paid call must complete");
    }
}
