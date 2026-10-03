// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ICashbackRouter {
    /// @notice Called by the gateway when an order is settled. Records `units` of transistor cashback owed to `payer`.
    function credit(bytes32 orderId, address payer, uint32 units) external;
}
