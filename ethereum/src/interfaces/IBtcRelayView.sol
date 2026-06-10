// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title IBtcRelayView
/// @notice Read-only interface for the Atomiq BtcRelay contract.
///         Based on the upstream IBtcRelayView from atomiqlabs/atomiq-contracts-evm.
///         Note: verifyBlockheader(StoredBlockHeader) is omitted because it depends
///         on an external struct; use verifyBlockheaderHash instead.
interface IBtcRelayView {
    /// @notice Returns the cumulative proof-of-work of the current chain tip.
    function getChainwork() external view returns (uint224);

    /// @notice Returns the current tip block height.
    function getBlockheight() external view returns (uint32);

    /// @notice Verify that a block header at the given height matches the commitment hash.
    /// @param height          Bitcoin block height.
    /// @param commitmentHash  keccak256 commitment of the StoredBlockHeader.
    /// @return confirmations  Number of confirmations (tip - height + 1). Reverts if unknown.
    function verifyBlockheaderHash(
        uint256 height,
        bytes32 commitmentHash
    ) external view returns (uint256 confirmations);

    /// @notice Returns the commitment hash stored for a given block height.
    function getCommitHash(uint256 height) external view returns (bytes32);

    /// @notice Returns the commitment hash of the current chain tip.
    function getTipCommitHash() external view returns (bytes32);
}
