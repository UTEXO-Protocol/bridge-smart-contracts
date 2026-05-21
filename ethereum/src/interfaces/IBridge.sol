// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IBridge {
    // =========================================================================
    // Errors
    // =========================================================================

    error InvalidDestinationAddress();
    error InvalidDestinationChainId();
    error InvalidSourceChainId();
    error InvalidRouteRegistryAddress();
    error InvalidCommissionManagerAddress();
    error NotLZAdapter();
    error BurnIdAlreadyConsumed(uint256 burnId);
    error NativeCommissionNotAllowedOnFundsOut();
    error NativeValueMismatch();

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted on every successful `setLZAdapter`.
    /// @param oldAdapter Previous trusted adapter (zero before first set).
    /// @param newAdapter New trusted adapter (zero disables the adapter overload).
    event LZAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);

    /// @notice Emitted on every successful `setRouteRegistry`.
    /// @param oldRegistry Previous registry (the constructor-supplied value
    ///                    before the first rotation).
    /// @param newRegistry New registry (non-zero by `setRouteRegistry` guard).
    event RouteRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    /// @param sender             Address that deposited the tokens (the EOA on the
    ///                           public overload, or the LZ adapter on the
    ///                           adapter-only overload).
    /// @param operationId        Backend-assigned operation identifier.
    /// @param amount             Gross amount the user supplied (pre-commission).
    /// @param netAmount          Amount actually bridged after token commission is taken.
    /// @param tokenCommission    Fee charged in the bridged token (deducted from `amount`).
    /// @param nativeCommission   Fee charged in native wei (paid via `msg.value`).
    /// @param sourceChainId      EVM `block.chainid` for direct deposits, or the
    ///                           non-spoofable chain id forwarded by the adapter.
    /// @param destinationChainId Target chain id (backend-assigned for non-EVM
    ///                           destinations like RGB / Bitcoin).
    /// @param destinationAddress Target address on the destination chain.
    event BridgeFundsIn(
        address indexed sender,
        uint256 operationId,
        uint256 amount,
        uint256 netAmount,
        uint256 tokenCommission,
        uint256 nativeCommission,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string  destinationAddress
    );

    /// @param recipient          Recipient on this chain.
    /// @param amount             Gross amount released from the bridge pool (pre-commission).
    /// @param netAmount          Amount actually delivered to `recipient`.
    /// @param tokenCommission    Fee taken in the bridged token (sent to the CommissionManager).
    /// @param burnId             Identifier extracted from the burn consignment on the
    ///                           source side. Stored on-chain to block fundsOut replays.
    /// @param sourceChainId      Source chain id (non-EVM side for RGB→EVM releases).
    /// @param destinationChainId Destination chain id (EVM target receiving the release).
    /// @param sourceAddress      Sender address on the source chain.
    event BridgeFundsOut(
        address indexed recipient,
        uint256 amount,
        uint256 netAmount,
        uint256 tokenCommission,
        uint256 burnId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string  sourceAddress
    );

    // =========================================================================
    // External — user-facing
    // =========================================================================

    /// @notice Direct deposit overload for EVM users on this chain. The
    ///         `sourceChainId` half of the commission route key is filled with
    ///         `block.chainid` — non-spoofable by the caller.
    /// @dev Payable: if the active route uses NATIVE commission currency, `msg.value`
    ///      must equal the quoted native commission; otherwise `msg.value` must be 0.
    /// @dev `settlementData` is an opaque per-route blob forwarded into the
    ///      route's `ISettlementModule.onFundsIn`. Routes whose module does not
    ///      consume any extra data (e.g. RGB) accept an empty bytes string.
    function fundsIn(
        uint256 amount,
        uint256 destinationChainId,
        string  calldata destinationAddress,
        uint256 operationId,
        bytes   calldata settlementData
    ) external payable;

    /// @notice Adapter-only overload. Used by `UtexoLZAdapter.lzCompose` to
    ///         forward a cross-chain deposit while preserving the original
    ///         source-chain id (carried in `composeMsg` from the source side).
    /// @dev Reverts `NotLZAdapter` if `msg.sender` is not the configured
    ///      `lzAdapter`. Until federation sets a non-zero adapter, the
    ///      overload is effectively closed.
    function fundsIn(
        uint256 amount,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string  calldata destinationAddress,
        uint256 operationId,
        bytes   calldata settlementData
    ) external payable;

    // =========================================================================
    // External — owner-only (called via MultisigProxy.execute)
    // =========================================================================

    /// @notice Release tokens to a recipient.
    ///
    ///       Only callable by owner (`MultisigProxy` via `execute()`).
    /// @dev `destinationChainId` is part of the CommissionManager route key
    ///      and lets the same Bridge serve multi-hop routes.
    /// @dev `burnId` is the common single-use replay guard enforced by Bridge
    ///      itself; it MUST be unique across every successful fundsOut call.
    /// @dev `proof` is opaque per-route data consumed by `IFinalityVerifier`.
    ///      `settlementData` is opaque per-route data consumed by
    ///      `ISettlementModule`. Each plugin owns its own encoding.
    function fundsOut(
        address recipient,
        uint256 amount,
        uint256 burnId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string  calldata sourceAddress,
        bytes   calldata proof,
        bytes   calldata settlementData
    ) external;

    // =========================================================================
    // External — admin (called via MultisigProxy)
    // =========================================================================

    /// @notice Updates the trusted LayerZero adapter address. Owner-only
    ///         (MultisigProxy in production). Passing `address(0)` disables
    ///         the adapter overload until a non-zero address is set again.
    function setLZAdapter(address newAdapter) external;

    /// @notice Updates the `RouteRegistry` reference Bridge dispatches
    ///         `onFundsIn` / `beforeFundsOut` through. Owner-only.
    function setRouteRegistry(address newRouteRegistry) external;

    /// @notice Current trusted adapter; `address(0)` means the adapter
    ///         overload is closed.
    function lzAdapter() external view returns (address);

    /// @notice Current `RouteRegistry` Bridge uses for route dispatch.
    function routeRegistry() external view returns (address);

    /// @notice Permanently blocked — ownership cannot be renounced.
    function renounceOwnership() external view;
}
