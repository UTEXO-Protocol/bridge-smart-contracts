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
    error RebalanceSameChain(uint256 chainId);
    error ChainSafetyLimitExceeded(uint256 chainId, uint256 requested, uint256 spentInWindow, uint256 windowLimit);
    error GlobalSafetyLimitExceeded(uint256 requested, uint256 spentInWindow, uint256 windowLimit);
    error InvalidOutflowPolicy(uint256 burstBps, uint256 refillBpsPerWindow, uint256 maxBps);
    error ZeroOutflowReference();

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
    /// @param chainId             Source chain the limit applies to.
    /// @param burstBps            Max instant outflow, in bps of reference liquidity.
    /// @param refillBpsPerWindow  Allowance restored per refill window, in bps.
    /// @param availableShares     Accrued allowance carried over, in shares.
    event OutflowLimitUpdated(
        uint256 indexed chainId, uint256 burstBps, uint256 refillBpsPerWindow, uint256 availableShares
    );

    /// @notice Emitted on `setGlobalOutflowLimit` (aggregate outflow token bucket).
    /// @param burstBps            Max instant aggregate outflow, in bps of reference TVL.
    /// @param refillBpsPerWindow  Allowance restored per refill window, in bps.
    /// @param availableShares     Accrued allowance carried over, in shares.
    event GlobalOutflowLimitUpdated(uint256 burstBps, uint256 refillBpsPerWindow, uint256 availableShares);

    /// @notice Emitted after an outflow consumes immutable per-chain rolling
    ///         safety allowance.
    event ChainSafetyOutflowConsumed(
        uint256 indexed chainId, uint256 amount, uint256 spentInWindow, uint256 windowLimit
    );

    /// @notice Emitted after a physical token outflow consumes immutable global
    ///         rolling safety allowance.
    event GlobalSafetyOutflowConsumed(uint256 amount, uint256 spentInWindow, uint256 windowLimit);

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

    /// @notice Emitted on every successful `rebalanceLiquidity`. The canonical
    ///         record of an accounting-only liquidity migration between two
    ///         chain buckets — no tokens move on this chain. When the
    ///         destination route's settlement module returns a non-zero RGB
    ///         OpId, the standard `FundsIn` event is emitted alongside (the RGB
    ///         side consumes `FundsIn` only and needs no rebalance awareness).
    /// @param operationId        Credit-leg canonical id, derived on-chain (keys
    ///                           the destination route's settlement record).
    /// @param burnId             Debit-leg replay key, shares the `consumedBurnIds`
    ///                           namespace with `fundsOut`.
    /// @param sourceChainId      Chain bucket debited.
    /// @param destinationChainId Chain bucket credited.
    /// @param amount             Amount migrated between the buckets (no commission).
    /// @param sourceAddress      Source-chain identity behind the debit (e.g. the
    ///                           RGB burner); its hash is folded into `operationId`.
    /// @param destinationAddress Destination-chain address backing the credit
    ///                           (e.g. the bridge's RGB wallet receiving a mint).
    event BridgeRebalance(
        bytes32 indexed operationId,
        uint256 indexed burnId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        uint256 amount,
        string sourceAddress,
        string destinationAddress
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

    /// @notice Parameters for `rebalanceLiquidity`.
    /// @param amount             Amount to migrate from the source bucket to the
    ///                           destination bucket. No commission is taken.
    /// @param burnId             Bridge-derived replay guard for the debit leg.
    ///                           Must equal the Bridge's canonical hash of the
    ///                           rebalance fields (no nonce — an identical intent
    ///                           can never execute twice, matching `fundsOut`).
    ///                           Lives in the same `consumedBurnIds` namespace as
    ///                           `fundsOut` burn ids.
    /// @param sourceChainId      Chain whose bucket is debited (burn side).
    /// @param destinationChainId Chain whose bucket is credited (mint side).
    /// @param sourceAddress      Source-chain identity behind the debit;
    ///                           `keccak256(sourceAddress)` is folded into the
    ///                           credit-leg `operationId`.
    /// @param destinationAddress Destination-chain address backing the credit.
    /// @param proof              Opaque payload for the route's `IFinalityVerifier`
    ///                           (debit-leg source proof; e.g. BtcRelay pairs for
    ///                           an RGB burn).
    /// @param settlementDataOut  Opaque payload for the route module's
    ///                           `beforeFundsOut` (debit-leg settlement check).
    /// @param settlementDataIn   Opaque payload for the route module's
    ///                           `onFundsIn` (credit-leg settlement write).
    struct RebalanceParams {
        uint256 amount;
        uint256 burnId;
        uint256 sourceChainId;
        uint256 destinationChainId;
        string sourceAddress;
        string destinationAddress;
        bytes proof;
        bytes settlementDataOut;
        bytes settlementDataIn;
    }

    /// @notice Migrate isolated liquidity between two chain buckets without
    ///         moving tokens: debit `lockedLiquidity[sourceChainId]`, credit
    ///         `lockedLiquidity[destinationChainId]`, atomically and
    ///         proof-gated via the `(sourceChainId, destinationChainId)` route.
    ///         Composition: the debit leg is `fundsOut` minus the token payout
    ///         (replay guard, route verifier + settlement check, bucket debit,
    ///         per-chain rate limit); the credit leg is `fundsIn` minus the
    ///         token pull (operationId derivation, settlement write, bucket
    ///         credit, `FundsIn` emission for RGB destinations).
    ///         Only callable by owner (`MultisigProxy`, TEE M-of-N — the
    ///         source chain's enclave set attests the funds left that chain).
    /// @dev Consumes the source chain's outflow bucket (release capacity is
    ///      migrating away) but NOT the global bucket (no token egress; the
    ///      eventual physical exit pays the global bucket in `fundsOut`).
    ///      Gated on `whenOutflowNotPaused` only: an inflow-only pause is
    ///      documented as "withdrawals stay open for liquidity migration", and
    ///      this is exactly a liquidity migration.
    function rebalanceLiquidity(RebalanceParams calldata params) external;

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
    ///         `chainId`. Owner-only (MultisigProxy timelock flow).
    ///
    ///         Both parameters are basis points of the chain's reference
    ///         liquidity, not absolute token units: `burstBps` is the maximum
    ///         instant outflow and `refillBpsPerWindow` the allowance restored
    ///         over one `BUCKET_REFILL_WINDOW`. The bucket therefore tracks
    ///         liquidity automatically — the same policy means 5k at 100k TVL
    ///         and 50k at 1M TVL, with no governance retuning.
    ///
    ///         Validation is liquidity-independent — both values must be
    ///         non-zero and their sum must not exceed
    ///         `MAX_CHAIN_OUTFLOW_BPS` — so a policy can be installed at
    ///         deployment before any deposit exists. This combined bound makes
    ///         a full-TVL bucket and an over-permissive burst/refill pair
    ///         unrepresentable at every liquidity level.
    ///         Reverts `InvalidOutflowLimit` on zero `chainId` and
    ///         `InvalidOutflowPolicy` on an out-of-range policy.
    ///
    ///         A reconfiguration accrues the pending refill under the old policy
    ///         and preserves the accrued allowance (clamped to the new burst) —
    ///         it never gifts a fresh full burst.
    function setOutflowLimit(uint256 chainId, uint256 burstBps, uint256 refillBpsPerWindow) external;

    /// @notice Configure (or reconfigure) the global (aggregate) outflow token
    ///         bucket that bounds total `fundsOut` across all source chains.
    ///         Owner-only. Same bps semantics, combined burst-plus-refill bound
    ///         (against `MAX_GLOBAL_OUTFLOW_BPS`) and accrue-and-preserve
    ///         behaviour as `setOutflowLimit`.
    function setGlobalOutflowLimit(uint256 burstBps, uint256 refillBpsPerWindow) external;

    /// @notice Spendable per-chain bucket allowance right now in token units,
    ///         including the refill accrued since the last update (which the
    ///         stored `chainBuckets` getter does not materialize, and which it
    ///         reports in shares rather than tokens). Returns 0 for an
    ///         unconfigured chain.
    function availableOutflow(uint256 chainId) external view returns (uint256);

    /// @notice Spendable global bucket allowance right now in token units,
    ///         including the accrued refill. Returns 0 if the global bucket is
    ///         unconfigured.
    function availableGlobalOutflow() external view returns (uint256);

    /// @notice Remaining immutable per-chain safety allowance in the current
    ///         rolling window. Independent of the configurable token bucket.
    function availableChainSafetyOutflow(uint256 chainId) external view returns (uint256);

    /// @notice Remaining immutable global safety allowance in the current
    ///         rolling window. Independent of the configurable token bucket.
    function availableGlobalSafetyOutflow() external view returns (uint256);

    /// @notice Reference liquidity every percentage in this contract is measured
    ///         against for `chainId`: accounted liquidity plus usage still
    ///         counted in the rolling window. Constant while releases drain
    ///         liquidity inside one window — each release moves the same amount
    ///         from one term to the other — and it steps down to plain
    ///         `lockedLiquidity` once that usage expires. Both the configurable
    ///         bucket and the immutable safety limit are denominated against it.
    function chainOutflowReference(uint256 chainId) external view returns (uint256);

    /// @notice Aggregate counterpart of `chainOutflowReference`.
    function globalOutflowReference() external view returns (uint256);

    /// @notice The amount `fundsOut` would actually permit for `chainId` right
    ///         now, in token units: the minimum of isolated chain liquidity,
    ///         both token buckets and both immutable safety allowances. Use this
    ///         rather than the single-layer views when asking "how much can
    ///         leave" — no individual layer answers that question.
    function effectiveAvailableOutflow(uint256 chainId) external view returns (uint256);

    /// @notice Current trusted adapter; `address(0)` means the adapter
    ///         overload is closed.
    function lzAdapter() external view returns (address);

    /// @notice Current `RouteRegistry` Bridge uses for route dispatch.
    function routeRegistry() external view returns (address);

    /// @notice Permanently blocked — ownership cannot be renounced.
    function renounceOwnership() external view;
}
