// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

interface IBridgeProxy {
    function implementation() external view returns (address);

    /// @notice Upgrade the implementation and optionally delegatecall initialization data.
    /// @dev Owner-only. Data is capped at 4096 bytes including its selector; empty is allowed.
    ///      Authorization reads the OpenZeppelin Ownable owner slot directly.
    ///      Initialization must preserve this stored owner.
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}
