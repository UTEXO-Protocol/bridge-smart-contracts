// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title IRgbSettlementModule
/// @notice Read-only RGB mint-record surface consumed by Bridge.
interface IRgbSettlementModule {
    /// @notice Returns the funded Arbitrum L2 height encoded as block + 1.
    /// @dev Zero means that the operation id has no record in this module.
    function fundsInRecordL2Blocks(bytes32 operationId) external view returns (uint64 l2BlockPlusOne);
}
