// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IFinalityVerifier } from '../interfaces/IFinalityVerifier.sol';
import { FundsOutContext }   from '../interfaces/RouteTypes.sol';
import { IBtcRelayView }     from '../interfaces/IBtcRelayView.sol';

/// @title RGBVerifier
/// @notice `IFinalityVerifier` for the RGB → Arbitrum route. Confirms that
///         the source-side burn was packaged into a finalised Bitcoin block
///         by delegating to the Atomiq `IBtcRelayView` SPV relay.
///
/// @dev Stateless apart from the immutable `btcRelay` reference. There is
///      no admin, no pause, no upgrade. To repoint at a different BtcRelay
///      deployment, deploy a fresh `RGBVerifier` and rotate the route via
///      `RouteRegistry.setRoute(...)` under federation governance.
///
///      The `proof` blob layout is fixed by this verifier:
///        `abi.encode(uint256 blockHeight, bytes32 commitmentHash)`
///      The TEE supplies these two values inside its signed call data; the
///      verifier decodes them, queries the BtcRelay, and reverts on any
///      failure (unknown height, mismatched commitment, ABI-decode error).
contract RGBVerifier is IFinalityVerifier {
    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Constructor was called with `address(0)`.
    error InvalidBtcRelayAddress();

    // =========================================================================
    // Storage
    // =========================================================================

    /// @notice The Atomiq BtcRelay contract this verifier delegates to.
    address public immutable btcRelay;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param btcRelay_ Address of the deployed `IBtcRelayView` (Atomiq
    ///                  BtcRelay) on the same chain as Bridge.
    constructor(address btcRelay_) {
        if (btcRelay_ == address(0)) revert InvalidBtcRelayAddress();
        btcRelay = btcRelay_;
    }

    // =========================================================================
    // IFinalityVerifier
    // =========================================================================

    /// @inheritdoc IFinalityVerifier
    /// @dev Decodes `proof` as `(uint256 blockHeight, bytes32 commitmentHash)`
    ///      and forwards them to `IBtcRelayView.verifyBlockheaderHash`. The
    ///      BtcRelay reverts when the block is unknown or the commitment
    ///      mismatches.
    function verify(FundsOutContext calldata, bytes calldata proof) external view override {
        (uint256 blockHeight, bytes32 commitmentHash) = abi.decode(proof, (uint256, bytes32));

        // `verifyBlockheaderHash` reverts on any failure (unknown height,
        // mismatched commitment hash, …). The success path returns
        // `confirmations` (uint256), which we intentionally discard: TEE
        // callers already gate on confirmation depth off-chain before they
        // sign, so on-chain enforcement here would be a redundant policy
        // owned by two places.
        IBtcRelayView(btcRelay).verifyBlockheaderHash(blockHeight, commitmentHash);
    }
}
