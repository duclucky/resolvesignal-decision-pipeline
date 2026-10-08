// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ExactEscrowFactory} from "../src/ExactEscrowFactory.sol";

interface DeployVm {
    function envAddress(string calldata name) external returns (address);
    function envUint(string calldata name) external returns (uint256);
    function startBroadcast() external;
    function stopBroadcast() external;
}

/// @notice Deploys the factory after an explicit Arc network and role check.
/// @dev Configure broadcast signing with an encrypted keystore or managed signer.
contract DeployArcEscrow {
    DeployVm private constant vm = DeployVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external returns (ExactEscrowFactory deployed) {
        require(block.chainid == 5042 || block.chainid == 5042002, "Arc only");
        require(vm.envUint("ESCROW_EXPECTED_CHAIN_ID") == block.chainid, "explicit chain mismatch");
        address operator = vm.envAddress("ESCROW_OPERATOR");
        address treasury = vm.envAddress("ESCROW_TREASURY");
        require(operator != address(0) && treasury != address(0), "roles required");
        vm.startBroadcast();
        deployed = new ExactEscrowFactory(operator, treasury);
        vm.stopBroadcast();
    }
}
