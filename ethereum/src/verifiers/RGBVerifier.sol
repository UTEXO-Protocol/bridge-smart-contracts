// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IFinalityVerifier } from '../interfaces/IFinalityVerifier.sol';
import { FundsOutContext }   from '../interfaces/RouteTypes.sol';
import { IBtcRelayView }     from '../interfaces/IBtcRelayView.sol';

/// @title RGBVerifier
/// @notice `IFinalityVerifier` for the RGB → Arbitrum route. Confirms that
///         the source-side operation (RGB burn or lock) was packaged into a
///         finalised Bitcoin block by delegating to the Atomiq `IBtcRelayView`
///         SPV relay.
///
/// @dev Stateless apart from the immutable `btcRelay` reference. There is
///      no admin, no pause, no upgrade. To repoint at a different BtcRelay
///      deployment, deploy a fresh `RGBVerifier` and rotate the route via
///      `RouteRegistry.setRoute(...)` under federation governance.
///
///      The `proof` blob layout is fixed by this verifier — two
///      `(height, commitmentHash)` pairs:
///        `abi.encode(uint256 sourceHeight, bytes32 sourceCommit,
///                    uint256 latestHeight, bytes32 latestCommit)`
///      The source pair identifies the block that packaged the RGB burn/lock;
///      the latest pair identifies a block at the relay head. The TEE supplies
///      both inside its signed call data; the verifier decodes them, queries
///      the BtcRelay, and reverts on any failure (unknown height, mismatched
///      commitment, ABI-decode error) or if the confirmation-depth invariants
///      below fail. Depth thresholds are compile-time constants; retune by
///      redeploying and rotating the route.
contract RGBVerifier is IFinalityVerifier {
    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Constructor was called with `address(0)`.
    error InvalidBtcRelayAddress();

    /// @notice Constructor received a config that could never accept a proof
    ///         (`maxLatestConfirmations == 0` — a known block always has >= 1).
    error InvalidThresholds();

    /// @notice The source block (RGB burn/lock) is not buried deeply enough.
    error InsufficientSourceConfirmations(uint256 confirmations, uint256 required);

    /// @notice The latest block is not close enough to the relay head, so the
    ///         relay's view of the chain may be stale.
    error RelayNotFresh(uint256 confirmations, uint256 maxAllowed);

    /// @notice The source block is not buried far enough beneath the fresh
    ///         latest block.
    error InsufficientConfirmationGap(uint256 sourceConfirmations, uint256 latestConfirmations, uint256 requiredGap);

    // =========================================================================
    // Storage / configuration
    // =========================================================================

    /// @notice The Atomiq BtcRelay contract this verifier delegates to.
    address public immutable btcRelay;

    /// @notice Minimum confirmations the source block (RGB burn/lock) must have
    ///         (Bitcoin's high-value settlement convention, typically 6). Set at
    ///         deploy; retune by redeploying the verifier and rotating the route.
    uint256 public immutable minSourceConfirmations;

    /// @notice Maximum confirmations the latest block may have (typically 1). A
    ///         fresh latest block sits at the relay head, proving the relay is
    ///         current. Set at deploy.
    uint256 public immutable maxLatestConfirmations;

    /// @notice Minimum confirmation gap between the source block and the fresh
    ///         latest block (typically 5). Set at deploy.
    uint256 public immutable minConfirmationGap;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param btcRelay_               Address of the deployed `IBtcRelayView`
    ///                                (Atomiq BtcRelay) on the same chain as Bridge.
    /// @param minSourceConfirmations_ Minimum depth of the source (burn/lock) block.
    /// @param maxLatestConfirmations_ Maximum depth of the latest (freshness) block; must be >= 1.
    /// @param minConfirmationGap_     Minimum depth gap between source and latest.
    constructor(
        address btcRelay_,
        uint256 minSourceConfirmations_,
        uint256 maxLatestConfirmations_,
        uint256 minConfirmationGap_
    ) {
        if (btcRelay_ == address(0)) revert InvalidBtcRelayAddress();
        if (maxLatestConfirmations_ == 0) revert InvalidThresholds();
        btcRelay               = btcRelay_;
        minSourceConfirmations = minSourceConfirmations_;
        maxLatestConfirmations = maxLatestConfirmations_;
        minConfirmationGap     = minConfirmationGap_;
    }

    // =========================================================================
    // IFinalityVerifier
    // =========================================================================

    /// @inheritdoc IFinalityVerifier
    /// @dev Decodes `proof` as two `(height, commitmentHash)` pairs:
    ///        `abi.encode(sourceHeight, sourceCommit, latestHeight, latestCommit)`
    ///      - the source pair identifies the block that packaged the RGB
    ///        burn/lock;
    ///      - the latest pair identifies a block at the relay head (freshness).
    ///      Both are checked against `IBtcRelayView.verifyBlockheaderHash`,
    ///      which reverts on an unknown height or mismatched commitment and
    ///      otherwise returns the block's confirmation depth. On top of that
    ///      this verifier enforces, on-chain:
    ///        - the source block is buried at least `minSourceConfirmations` deep;
    ///        - the latest block is at most `maxLatestConfirmations` deep (fresh relay);
    ///        - the source is buried at least `minConfirmationGap` blocks beneath
    ///          the fresh latest block.
    function verify(FundsOutContext calldata, bytes calldata proof) external view override {
        (uint256 sourceHeight, bytes32 sourceCommit, uint256 latestHeight, bytes32 latestCommit) =
            abi.decode(proof, (uint256, bytes32, uint256, bytes32));

        // Both blocks must exist in the relay with matching commitments
        // (verifyBlockheaderHash reverts otherwise); it returns the depth.
        uint256 sourceConfirmations = IBtcRelayView(btcRelay).verifyBlockheaderHash(sourceHeight, sourceCommit);
        uint256 latestConfirmations = IBtcRelayView(btcRelay).verifyBlockheaderHash(latestHeight, latestCommit);

        // Source block buried deeply enough.
        if (sourceConfirmations < minSourceConfirmations) {
            revert InsufficientSourceConfirmations(sourceConfirmations, minSourceConfirmations);
        }
        // Latest block near the relay head — the relay's chain view is current.
        if (latestConfirmations > maxLatestConfirmations) {
            revert RelayNotFresh(latestConfirmations, maxLatestConfirmations);
        }
        // Source buried at least minConfirmationGap beneath the fresh latest.
        // Written as an addition to avoid underflow if the pairs are swapped.
        if (sourceConfirmations < latestConfirmations + minConfirmationGap) {
            revert InsufficientConfirmationGap(sourceConfirmations, latestConfirmations, minConfirmationGap);
        }
    }
}
