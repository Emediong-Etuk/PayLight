// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @notice USD₮0 on X Layer (0x779Ded0c9e1022225f8E0630b35a9b54bE713736): 6 decimals, EIP-2612 permit
///         (domain name "USD₮0", version "1") and EIP-3009 — all verified on-chain (docs/RESEARCH.md Q15).
interface IUSDT0 is IERC20, IERC20Permit {
    /// @notice EIP-3009. Requires msg.sender == to, so only the payee contract can redeem the authorization.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}
