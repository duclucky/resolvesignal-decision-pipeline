// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

interface Vm {
    function addr(uint256) external returns (address);
    function sign(uint256, bytes32) external returns (uint8, bytes32, bytes32);
    function prank(address) external;
    function warp(uint256) external;
    function chainId(uint256) external;
    function expectRevert(bytes4) external;
    function expectRevert() external;
    function etch(address, bytes calldata) external;
}

/// @dev Local-only token model. Arc's production USDC/native-USDC behavior is not fully simulated.
contract MockUSDC is ERC20, EIP712 {
    bytes32 public constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    mapping(address => mapping(bytes32 => bool)) public authorizationState;
    bool public rejectTransfers;
    bool public shortTransfer;
    address public hook;
    bytes public hookData;
    bool public hookSucceeded;
    bytes4 public hookError;

    constructor() ERC20("USDC", "USDC") EIP712("USDC", "2") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRejectTransfers(bool value) external {
        rejectTransfers = value;
    }

    function setShortTransfer(bool value) external {
        shortTransfer = value;
    }

    function setHook(address target, bytes calldata data) external {
        hook = target;
        hookData = data;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(!rejectTransfers, "blocked_transfer");
        if (shortTransfer && from != address(0) && to != address(0)) {
            super._update(from, to, amount - 1);
            super._update(from, address(0), 1);
        } else {
            super._update(from, to, amount);
        }
        if (hook != address(0)) {
            address target = hook;
            hook = address(0);
            bytes memory errorData;
            (hookSucceeded, errorData) = target.call(hookData);
            if (errorData.length >= 4) hookError = bytes4(errorData);
        }
    }
}

/// @dev Selective blocklist model used to verify retryable transfer failures.
contract AuditBlocklistUSDC is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function setBlocked(address who, bool value) external {
        blocked[who] = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[from] && !blocked[to], "blocklisted");
        super._update(from, to, value);
    }
}

/// @dev Models an ERC-1271 operator whose signing policy can be revoked.
contract AuditRevocableOperator is IERC1271 {
    address private immutable owner;
    bool public revoked;

    constructor(address owner_) {
        owner = owner_;
    }

    function revoke() external {
        revoked = true;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        if (revoked) return bytes4(0xffffffff);
        return ECDSA.recover(hash, signature) == owner ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}
