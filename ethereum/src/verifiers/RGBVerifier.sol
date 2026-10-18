// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IFinalityVerifier} from "../interfaces/IFinalityVerifier.sol";
import {FundsOutContext} from "../interfaces/RouteTypes.sol";
import {IBtcRelayView} from "../interfaces/IBtcRelayView.sol";

/// @title RGBVerifier
/// @notice Checks Bitcoin commitments and confirmation depths for RGB releases and rebalances.
/// @dev `proof` is `abi.encode(uint256 sourceHeight, bytes32 sourceCommit,
///      uint256 latestHeight, bytes32 latestCommit)`. The source pair identifies the
///      operation's anchoring block; latest bounds proof freshness relative to the relay tip.
///      Both commitments are checked against `btcRelay`. Thresholds are immutable;
///      enclaves validate the consignment and its relationship to these blocks.
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

    /// @notice The proof's latest block exceeds the permitted depth relative to the relay tip.
    /// @dev Does not establish whether the relay itself is synchronized with Bitcoin.
    error RelayNotFresh(uint256 confirmations, uint256 maxAllowed);

    /// @notice The source block is not buried far enough beneath the fresh
    ///         latest block.
    error InsufficientConfirmationGap(uint256 sourceConfirmations, uint256 latestConfirmations, uint256 requiredGap);

    /// @notice The RGB release or rebalance supplied a non-empty `sourceAddress`.
    /// @dev This bridge uses an empty sourceAddress for RGB so alternate strings cannot
    ///      produce different replay keys for the same burn.
    error UnexpectedSourceAddress();

    // =========================================================================
    // Storage / configuration
    // =========================================================================

    /// @notice The Atomiq BtcRelay contract this verifier delegates to.
    address public immutable btcRelay;

    /// @notice Minimum confirmation depth of the source block.
    uint256 public immutable minSourceConfirmations;

    /// @notice Maximum permitted confirmation depth of the proof's latest block.
    uint256 public immutable maxLatestConfirmations;

    /// @notice Minimum depth difference between source and latest blocks.
    uint256 public immutable minConfirmationGap;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param btcRelay_              Address of the deployed `IBtcRelayView`
    ///                               (Atomiq BtcRelay) on the same chain as Bridge.
    /// @param minSourceConfirmations_ Minimum depth of the source (burn/lock) block.
    /// @param maxLatestConfirmations_ Maximum depth of the latest (freshness) block; must be >= 1.
    /// @param minConfirmationGap_    Minimum depth gap between source and latest.
    constructor(
        address btcRelay_,
        uint256 minSourceConfirmations_,
        uint256 maxLatestConfirmations_,
        uint256 minConfirmationGap_
    ) {
        if (btcRelay_ == address(0)) revert InvalidBtcRelayAddress();
        if (maxLatestConfirmations_ == 0) revert InvalidThresholds();
        btcRelay = btcRelay_;
        minSourceConfirmations = minSourceConfirmations_;
        maxLatestConfirmations = maxLatestConfirmations_;
        minConfirmationGap = minConfirmationGap_;
    }

    // =========================================================================
    // IFinalityVerifier
    // =========================================================================

    /// @inheritdoc IFinalityVerifier
    /// @dev Requires empty sourceAddress and enforces source depth, latest depth and gap.
    function verify(FundsOutContext calldata ctx, bytes calldata proof) external view override {
        // Keep the replay-key address canonical; RGB details are validated in the consignment.
        if (bytes(ctx.sourceAddress).length != 0) revert UnexpectedSourceAddress();

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
        // Bound the age of the proof's latest block relative to the relay head.
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
