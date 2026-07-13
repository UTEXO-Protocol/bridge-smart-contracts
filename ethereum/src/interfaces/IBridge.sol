// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

interface IBridge {
    // =========================================================================
    // Errors
    // =========================================================================

    error InvalidDestinationAddress();
    error InvalidDestinationChainId();
    error InvalidSourceChainId();
    error ZeroAmount();
    error AmountBelowMinimum(uint256 amount, uint256 minimum);
    error InsufficientReceived(uint256 received, uint256 tokenCommission);
    error InvalidMinFundsInAmount();
    error AddressTooLong(uint256 length, uint256 maxLength);
    error ProofTooLong(uint256 length, uint256 maxLength);
    error SettlementDataTooLong(uint256 length, uint256 maxLength);
    error InsufficientChainLiquidity(uint256 chainId, uint256 requested, uint256 available);
    error InvalidOutflowLimit();
    error InvalidRouteRegistryAddress();
    error InvalidCommissionManagerAddress();
    error NotLZAdapter();
    error InvalidLZAdapter();
    error InvalidBurnId(uint256 provided, uint256 expected);
    error BurnIdAlreadyConsumed(uint256 burnId);
    error NativeValueMismatch();

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted on every successful `setLZAdapter` (rotation to a
    ///         non-zero adapter).
    /// @param oldAdapter Previous trusted adapter (zero before first set).
    /// @param newAdapter New trusted adapter (always non-zero).
    event LZAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);

    /// @notice Emitted on `disableLZAdapter` — the inbound adapter path is
    ///         explicitly closed (distinct from a rotation).
    /// @param oldAdapter Adapter that was cleared.
    event LZAdapterDisabled(address indexed oldAdapter);

    /// @notice Emitted on every successful `setRouteRegistry`.
    /// @param oldRegistry Previous registry (the constructor-supplied value
    ///                    before the first rotation).
    /// @param newRegistry New registry (non-zero by `setRouteRegistry` guard).
    event RouteRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    /// @notice Emitted on every successful `setMinFundsInAmount`.
    /// @param oldMinimum Previous minimum (constructor value before first update).
    /// @param newMinimum New minimum (in token smallest units; always non-zero).
    event MinFundsInAmountUpdated(uint256 oldMinimum, uint256 newMinimum);

    /// @notice Emitted on `setOutflowLimit` (per-chain outflow token bucket).
    /// @param chainId    Source chain the limit applies to.
    /// @param capacity   New bucket capacity (max instant outflow).
    /// @param refillRate New refill rate (token units per second).
    /// @param available  Accrued allowance carried over after the update.
    event OutflowLimitUpdated(uint256 indexed chainId, uint256 capacity, uint256 refillRate, uint256 available);

    /// @notice Emitted on `setGlobalOutflowLimit` (aggregate outflow token bucket).
    /// @param capacity   New bucket capacity (max instant aggregate outflow).
    /// @param refillRate New refill rate (token units per second).
    /// @param available  Accrued allowance carried over after the update.
    event GlobalOutflowLimitUpdated(uint256 capacity, uint256 refillRate, uint256 available);

    /// @notice RGB-route deposit event. Emitted only when the route's settlement
    ///         module returns a non-zero external correlation id — in practice
    ///         the RGB OpId, which the RGB side consumes as `uint256`. Routes
    ///         whose module returns 0 (e.g. `NullSettlementModule`) do not emit
    ///         it. The canonical, route-agnostic id is `BridgeFundsIn.operationId`
    ///         (bytes32); this event exists for the RGB integration only.
    /// @param sender  EVM caller Bridge saw (user, or the LZ adapter).
    /// @param rgbOpId RGB operation id, decoded by the route module from its
    ///                `settlementData`. Not an on-chain dedup key.
    /// @param amount  Net amount bridged (post-commission).
    event FundsIn(address indexed sender, uint256 indexed rgbOpId, uint256 amount);

    /// @param operationId        Canonical bridge-side operation id, derived
    ///                           on-chain by Bridge and unpredictable by third
    ///                           parties. This is the backend's canonical key.
    /// @param sourceSender       Original source-chain sender (left-padded to
    ///                           `bytes32`); the identity bound into `operationId`.
    /// @param sender             EVM caller Bridge saw (the EOA on the public
    ///                           overload, or the LZ adapter on the adapter-only
    ///                           overload).
    /// @param senderNonce        Per-`(sourceChainId, sourceSender)` nonce folded
    ///                           into `operationId`.
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
        bytes32 indexed operationId,
        bytes32 indexed sourceSender,
        address indexed sender,
        uint256 senderNonce,
        uint256 amount,
        uint256 netAmount,
        uint256 tokenCommission,
        uint256 nativeCommission,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string destinationAddress
    );

    /// @param recipient          Recipient on this chain.
    /// @param amount             Gross amount released from the bridge pool (pre-commission).
    /// @param netAmount          Amount actually delivered to `recipient`.
    /// @param tokenCommission    Fee taken in the bridged token (sent to the CommissionManager).
    /// @param burnId             Bridge-derived replay key. Stored on-chain to
    ///                           block fundsOut replays for the same release intent.
    /// @param sourceChainId      Source chain id (non-EVM side for RGB→EVM releases).
    /// @param destinationChainId Destination chain id (EVM target receiving the release).
    /// @param sourceAddress      Sender address on the source chain.
    event BridgeFundsOut(
        address indexed recipient,
        uint256 amount,
        uint256 netAmount,
        uint256 tokenCommission,
        uint256 indexed burnId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string sourceAddress
    );

    // =========================================================================
    // External — user-facing
    // =========================================================================

    /// @notice Direct deposit overload for EVM users on this chain. The
    ///         `sourceChainId` half of the commission route key is filled with
    ///         `block.chainid` — non-spoofable by the caller.
    /// @dev Payable: if the active route uses NATIVE commission currency, `msg.value`
    ///      must be at least the quoted native commission — any surplus (from
    ///      favorable ETH/USD drift between quote and execution) is collected as
    ///      commission, not refunded (R-I-03). If the route takes no native
    ///      commission (TOKEN currency), `msg.value` must be 0.
    /// @dev `settlementData` is an opaque per-route blob forwarded into the
    ///      route's `ISettlementModule.onFundsIn`. Routes whose module does not
    ///      consume any extra data (e.g. RGB) accept an empty bytes string.
    /// @dev The `operationId` is derived on-chain (not caller-supplied) and
    ///      returned; read the canonical value from the emitted event.
    /// @return operationId The canonical bridge-side operation id.
    function fundsIn(
        uint256 amount,
        uint256 destinationChainId,
        string calldata destinationAddress,
        bytes calldata settlementData
    ) external payable returns (bytes32 operationId);

    /// @notice Adapter-only overload. Used by `UtexoLZAdapter.lzCompose` to
    ///         forward a cross-chain deposit while preserving the original
    ///         source-chain id and sender (carried in `composeMsg` from the
    ///         source side).
    /// @dev Reverts `NotLZAdapter` if `msg.sender` is not the configured
    ///      `lzAdapter`. Until federation sets a non-zero adapter, the
    ///      overload is effectively closed. `sourceSender` is authenticated by
    ///      the source-chain entrypoint and adapter, not by an arbitrary
    ///      caller — it is bound into the derived `operationId`.
    /// @return operationId The canonical bridge-side operation id.
    function fundsIn(
        uint256 amount,
        uint256 sourceChainId,
        bytes32 sourceSender,
        uint256 destinationChainId,
        string calldata destinationAddress,
        bytes calldata settlementData
    ) external payable returns (bytes32 operationId);

    // =========================================================================
    // External — owner-only (called via MultisigProxy)
    // =========================================================================

    /// @notice Release parameters for `fundsOut`.
    /// @param recipient          Recipient on this chain.
    /// @param amount             Gross amount to release (pre-commission).
    /// @param burnId             Bridge-derived replay guard. Must equal the
    ///                           Bridge's canonical hash of the release fields,
    ///                           including `proof` and `settlementData`.
    /// @param sourceChainId      Source chain id.
    /// @param destinationChainId Destination chain id; part of the
    ///                           CommissionManager route key.
    /// @param sourceAddress      Sender address on the source chain.
    /// @param proof              Opaque per-route data for `IFinalityVerifier`.
    /// @param settlementData     Opaque per-route data for `ISettlementModule`.
    struct FundsOutParams {
        address recipient;
        uint256 amount;
        uint256 burnId;
        uint256 sourceChainId;
        uint256 destinationChainId;
        string sourceAddress;
        bytes proof;
        bytes settlementData;
    }

    /// @notice Release tokens to a recipient. Only callable by owner
    ///         (`MultisigProxy`). Parameters are bundled in `FundsOutParams`.
    /// @dev Per-chain / global outflow rate limiting uses the outflow
    ///      token-bucket library; bucket state is exposed via the `chainBuckets`
    ///      / `globalBucket` getters and the `availableOutflow` previews.
    function fundsOut(FundsOutParams calldata params) external;

    // =========================================================================
    // External — admin (called via MultisigProxy)
    // =========================================================================

    /// @notice Rotates the trusted LayerZero adapter to a new non-zero address.
    ///         Owner-only (MultisigProxy in production). Reverts
    ///         `InvalidLZAdapter` on `address(0)` — use `disableLZAdapter` to
    ///         close the adapter overload.
    function setLZAdapter(address newAdapter) external;

    /// @notice Explicitly clears the trusted LayerZero adapter (closes the
    ///         adapter `fundsIn` overload). Owner-only. Emits `LZAdapterDisabled`,
    ///         distinct from the `LZAdapterUpdated` rotation event.
    function disableLZAdapter() external;

    /// @notice Updates the `RouteRegistry` reference Bridge dispatches
    ///         `onFundsIn` / `beforeFundsOut` through. Owner-only.
    function setRouteRegistry(address newRouteRegistry) external;

    /// @notice Updates the minimum accepted `fundsIn` deposit (token smallest
    ///         units). Owner-only (MultisigProxy via the federation
    ///         propose -> timelock -> execute flow). Must be non-zero; reverts
    ///         `InvalidMinFundsInAmount` otherwise.
    function setMinFundsInAmount(uint256 newMinimum) external;

    /// @notice Current minimum accepted `fundsIn` deposit in token smallest
    ///         units. Always non-zero.
    function minFundsInAmount() external view returns (uint256);

    /// @notice Configure (or reconfigure) the per-chain outflow token bucket for
    ///         `chainId`. Owner-only (MultisigProxy timelock flow). Reverts
    ///         `InvalidOutflowLimit` on zero `chainId` or zero `capacity`. A
    ///         reconfiguration accrues the pending refill under the old settings
    ///         and preserves the accrued `available` (clamped to the new
    ///         capacity) — it never gifts a fresh full burst.
    function setOutflowLimit(uint256 chainId, uint256 capacity, uint256 refillRate) external;

    /// @notice Configure (or reconfigure) the global (aggregate) outflow token
    ///         bucket that bounds total `fundsOut` across all source chains.
    ///         Owner-only. Same accrue-and-preserve semantics as
    ///         `setOutflowLimit`.
    function setGlobalOutflowLimit(uint256 capacity, uint256 refillRate) external;

    /// @notice Spendable per-chain outflow allowance right now, including the
    ///         refill accrued since the last update (which the stored
    ///         `chainBuckets` getter does not materialize). Returns 0 for an
    ///         unconfigured chain.
    function availableOutflow(uint256 chainId) external view returns (uint256);

    /// @notice Spendable global outflow allowance right now, including the
    ///         accrued refill. Returns 0 if the global bucket is unconfigured.
    function availableGlobalOutflow() external view returns (uint256);

    /// @notice Current trusted adapter; `address(0)` means the adapter
    ///         overload is closed.
    function lzAdapter() external view returns (address);

    /// @notice Current `RouteRegistry` Bridge uses for route dispatch.
    function routeRegistry() external view returns (address);

    /// @notice Permanently blocked — ownership cannot be renounced.
    function renounceOwnership() external view;
}
