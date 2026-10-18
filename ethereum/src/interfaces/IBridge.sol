// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ICommissionManager} from "./ICommissionManager.sol";

interface IBridge {
    /// @notice Stable marker accepted by BridgeProxy implementations.
    /// @dev Must be called directly on an implementation, never through delegatecall.
    function bridgeProxyCompatibilityUUID() external view returns (bytes32);

    /// @notice Initializes proxy storage with non-zero amount floors.
    /// @dev Requires `minFundsInAmount >= minFundsOutAmount`.
    function initialize(
        address usdt0,
        address routeRegistry,
        address payable commissionManager,
        address lzAdapter,
        uint256 minFundsInAmount,
        uint256 minFundsOutAmount,
        address initialOwner
    ) external;

    // =========================================================================
    // Errors
    // =========================================================================

    error InvalidDestinationChainId();
    error InvalidSourceChainId();
    error ZeroAmount();
    error ZeroNetAmount();
    error InvalidRgbOpId();
    error CommissionConservationBroken();
    error AmountBelowMinimum(uint256 amount, uint256 minimum);
    error InsufficientReceived(uint256 received, uint256 tokenCommission);
    error InvalidMinFundsInAmount();
    error InvalidMinFundsOutAmount();
    error InvalidAmountFloors(uint256 minFundsInAmount, uint256 minFundsOutAmount);
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
    error ZeroSourceBurnTxId();
    error BurnIdAlreadyConsumed(uint256 burnId);
    error NativeValueMismatch();
    error NativeCommissionOutOfBounds(uint256 provided, uint256 minimum, uint256 maximum);
    error NativeRefundFailed(address recipient, uint256 amount);
    error RebalanceSameChain(uint256 chainId);
    error ChainSafetyLimitExceeded(uint256 chainId, uint256 requested, uint256 spentInWindow, uint256 windowLimit);
    error GlobalSafetyLimitExceeded(uint256 requested, uint256 spentInWindow, uint256 windowLimit);
    error InvalidOutflowPolicy(uint256 burstBps, uint256 refillBpsPerWindow, uint256 maxBps);
    error ZeroOutflowReference();
    error ProxyCompatibilityCheckMustBeDirect();

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted on every successful `setLZAdapter` (rotation to a
    ///         non-zero adapter).
    /// @param oldAdapter             Previous adapter, including one set at initialization; zero
    ///                               while disabled.
    /// @param newAdapter             New trusted adapter (always non-zero).
    event LZAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);

    /// @notice Emitted on `disableLZAdapter` — the inbound adapter path is
    ///         explicitly closed (distinct from a rotation).
    /// @param oldAdapter             Adapter that was cleared.
    event LZAdapterDisabled(address indexed oldAdapter);

    /// @notice Emitted on every successful `setRouteRegistry`.
    /// @param oldRegistry            Previous registry (the initialization value
    ///                               before the first rotation).
    /// @param newRegistry            New registry (non-zero by `setRouteRegistry` guard).
    event RouteRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    /// @notice Emitted on every successful `setCommissionManager`.
    /// @param oldCommissionManager   Previous CommissionManager address.
    /// @param newCommissionManager   New non-zero CommissionManager address.
    event CommissionManagerUpdated(address indexed oldCommissionManager, address indexed newCommissionManager);

    /// @notice Emitted on every successful `setMinFundsInAmount`.
    /// @param oldMinimum             Previous minimum (initialization value before first update).
    /// @param newMinimum             New minimum (in token smallest units; always non-zero).
    event MinFundsInAmountUpdated(uint256 oldMinimum, uint256 newMinimum);

    /// @notice Emitted on every successful `setMinFundsOutAmount`.
    /// @param oldMinimum             Previous minimum (initialization value before first update).
    /// @param newMinimum             New minimum (in token smallest units; always non-zero).
    event MinFundsOutAmountUpdated(uint256 oldMinimum, uint256 newMinimum);

    /// @notice Emitted on `setOutflowLimit` (per-chain outflow token bucket).
    /// @param chainId                Source chain the limit applies to.
    /// @param burstBps               Max instant outflow, in bps of reference liquidity.
    /// @param refillBpsPerWindow     Allowance restored per refill window, in bps.
    /// @param availableShares        Available shares after configuration: full on first enable,
    ///                               carried and capped on updates.
    event OutflowLimitUpdated(
        uint256 indexed chainId, uint256 burstBps, uint256 refillBpsPerWindow, uint256 availableShares
    );

    /// @notice Emitted on `setGlobalOutflowLimit` (aggregate outflow token bucket).
    /// @param burstBps               Max instant aggregate outflow, in bps of reference TVL.
    /// @param refillBpsPerWindow     Allowance restored per refill window, in bps.
    /// @param availableShares        Available shares after configuration: full on first enable,
    ///                               carried and capped on updates.
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
    /// @param sender                 EVM caller Bridge saw (user, or the LZ adapter).
    /// @param rgbOpId                RGB operation id, decoded by the route module from its
    ///                               `settlementData`. Included in the RGB mint backing id
    ///                               together with the network and actual net amount.
    /// @param amount                 Net amount bridged (post-commission), bounded to the RGB `u64`
    ///                               range.
    event FundsIn(address indexed sender, uint256 indexed rgbOpId, uint64 amount);

    /// @param operationId            Canonical bridge-side operation id, derived
    ///                               on-chain by Bridge. RGB uses the mint identity;
    ///                               other routes use sender/nonce deposit context.
    ///                               This is the backend's canonical key.
    /// @param sourceSender           Original source-chain sender (left-padded to
    ///                               `bytes32`); bound into non-RGB `operationId`.
    /// @param sender                 EVM caller Bridge saw (the EOA on the public
    ///                               overload, or the LZ adapter on the adapter-only
    ///                               overload).
    /// @param senderNonce            Per-`(sourceChainId, sourceSender)` nonce folded
    ///                               into non-RGB `operationId`.
    /// @param amount                 Gross amount the user supplied (pre-commission).
    /// @param netAmount              Amount actually bridged after token commission is taken.
    /// @param tokenCommission        Fee charged in the bridged token (deducted from `amount`).
    /// @param nativeCommission       Fee charged in native wei (paid via `msg.value`).
    /// @param sourceChainId          EVM `block.chainid` for direct deposits, or the
    ///                               non-spoofable chain id forwarded by the adapter.
    /// @param destinationChainId     Destination chain id (EVM chain id, or 827166 for RGB).
    /// @param destinationAddress     Route-specific address; empty for RGB because it is in the
    ///                               consignment.
    /// @param settlementData         Opaque route-specific settlement payload.
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
        string destinationAddress,
        bytes settlementData
    );

    /// @param recipient              Recipient on this chain.
    /// @param amount                 Gross amount released from the bridge pool (pre-commission).
    /// @param netAmount              Net token payout before any token transfer fee.
    /// @param tokenCommission        Fee taken in the bridged token (sent to the
    ///                               CommissionManager).
    /// @param burnId                 Bridge-derived replay key shared by fundsOut and
    ///                               rebalanceLiquidity; the same source burn cannot be reused.
    /// @param sourceChainId          Source chain id (non-EVM side for RGB→EVM releases).
    /// @param destinationChainId     Destination chain id (EVM target receiving the release).
    /// @param sourceAddress          Source address; empty when the source network is RGB.
    /// @param settlementData         Opaque route-specific settlement payload.
    event BridgeFundsOut(
        address indexed recipient,
        uint256 amount,
        uint256 netAmount,
        uint256 tokenCommission,
        uint256 indexed burnId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string sourceAddress,
        bytes settlementData
    );

    /// @notice Emitted on every successful `rebalanceLiquidity`. The canonical
    ///         record of an accounting-only liquidity migration between two
    ///         chain buckets — no tokens move on this chain. When the
    ///         destination route's settlement module returns a non-zero RGB
    ///         OpId, the standard `FundsIn` event is emitted alongside (the RGB
    ///         side consumes `FundsIn` only and needs no rebalance awareness).
    /// @param operationId            Credit-leg canonical id, derived on-chain (keys
    ///                               the destination route's settlement record).
    /// @param burnId                 Debit-leg replay key, shares the `consumedBurnIds`
    ///                               namespace with `fundsOut`.
    /// @param sourceChainId          Chain bucket debited.
    /// @param destinationChainId     Chain bucket credited.
    /// @param amount                 Amount migrated between the buckets (no commission).
    /// @param sourceAddress          Source identity, empty for RGB sources; its hash enters the
    ///                               non-RGB credit-leg `operationId`.
    /// @param destinationAddress     Route-specific address; empty for RGB because it is in the
    ///                               consignment.
    /// @param settlementDataOut      Opaque debit-leg settlement payload.
    /// @param settlementDataIn       Opaque credit-leg settlement payload.
    event BridgeRebalance(
        bytes32 indexed operationId,
        uint256 indexed burnId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        uint256 amount,
        string sourceAddress,
        string destinationAddress,
        bytes settlementDataOut,
        bytes settlementDataIn
    );

    // =========================================================================
    // External — user-facing
    // =========================================================================

    /// @notice Deposits tokens from the caller for a destination network.
    /// @dev Source chain is `block.chainid`. Token commission reduces net liquidity.
    ///      Native payment must be within [quote, quote + 5%]; excess is refunded.
    ///      A caller unable to receive native currency must send the exact execution-time
    ///      quote; refunding excess to it reverts with `NativeRefundFailed`.
    /// @param amount                 Gross token amount, at least `minFundsInAmount`.
    /// @param destinationChainId     Destination network id.
    /// @param destinationAddress     Route-specific address; empty for RGB because it is in the
    ///                               consignment.
    /// @param settlementData         Route payload; RGB uses `abi.encode(uint256 rgbOpId)`.
    /// @return operationId Bridge-derived deposit identifier.
    function fundsIn(
        uint256 amount,
        uint256 destinationChainId,
        string calldata destinationAddress,
        bytes calldata settlementData
    ) external payable returns (bytes32 operationId);

    /// @notice Canonical RGB mint backing id, reproducible from a validated
    ///         consignment and pinned Bridge, chain and token configuration.
    /// @dev Shared by deposits and RGB-destination rebalance credit legs.
    function rgbMintDepositId(uint256 rgbNetwork, uint256 rgbOpId, uint256 netAmount) external view returns (bytes32);

    /// @notice Deposits tokens from the configured adapter on behalf of a source-chain user.
    /// @dev The adapter authenticates `sourceChainId` and `sourceSender`. Native payment
    ///      is accepted within ±5% of the quote and collected in full, without refund.
    /// @param amount                 Gross token amount, at least `minFundsInAmount`.
    /// @param sourceChainId          Authenticated source network id.
    /// @param sourceSender           Authenticated source-chain sender, encoded as bytes32.
    /// @param destinationChainId     Destination network id.
    /// @param destinationAddress     Route-specific address; empty for RGB because it is in the
    ///                               consignment.
    /// @param settlementData         Route payload; RGB uses `abi.encode(uint256 rgbOpId)`.
    /// @return operationId Bridge-derived deposit identifier.
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
    /// @param recipient              Recipient on this chain.
    /// @param amount                 Gross amount to release (pre-commission).
    /// @param burnId                 Bridge-derived replay guard. Must equal the
    ///                               Bridge's canonical settlement hash shared by
    ///                               `fundsOut` and `rebalanceLiquidity`. It includes
    ///                               `sourceBurnTxId`, but not `settlementData`,
    ///                               the moving finality `proof`, the recipient or
    ///                               `destinationChainId`.
    /// @param sourceChainId          Source chain id.
    /// @param destinationChainId     Destination chain id; part of the
    ///                               CommissionManager route key.
    /// @param sourceAddress          Source address; empty when the source network is RGB.
    /// @param proof                  Opaque per-route data for `IFinalityVerifier`.
    /// @param settlementData         Opaque per-route data for `ISettlementModule`.
    /// @param sourceBurnTxId         Source-chain identifier of the burn being
    ///                               settled
    struct FundsOutParams {
        address recipient;
        uint256 amount;
        uint256 burnId;
        uint256 sourceChainId;
        uint256 destinationChainId;
        string sourceAddress;
        bytes proof;
        bytes settlementData;
        bytes32 sourceBurnTxId;
    }

    /// @notice Releases tokens to a recipient. Only callable by owner
    ///         (`MultisigProxy`). Parameters are bundled in `FundsOutParams`.
    /// @dev Per-chain / global outflow rate limiting uses the outflow
    ///      token-bucket library; bucket state is exposed via the `chainBuckets`
    ///      / `globalBucket` getters and the `availableOutflow` previews.
    ///      Requires token commission + net payout == gross amount, with a non-zero net payout.
    function fundsOut(FundsOutParams calldata params) external;

    /// @notice Accounting migration parameters for a rebalance.
    /// @param amount                 Token amount moved between liquidity buckets, without
    ///                               commission.
    /// @param burnId                 Canonical source-burn replay key shared with fundsOut.
    /// @param sourceChainId          Network whose bucket is debited.
    /// @param destinationChainId     Remote network whose bucket is credited; cannot equal
    ///                               `block.chainid`.
    /// @param sourceAddress          Source identity; empty when the source network is RGB.
    /// @param destinationAddress     Route-specific address; empty for RGB because it is in the
    ///                               consignment.
    /// @param proof                  Route-specific finality proof for the debit leg.
    /// @param settlementDataOut      Debit-leg settlement payload.
    /// @param settlementDataIn       Credit-leg settlement payload.
    /// @param sourceBurnTxId         Nonzero source-burn identifier, included in burnId.
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
        bytes32 sourceBurnTxId;
    }

    /// @notice Moves liquidity accounting between networks without transferring tokens.
    /// @dev Owner-only. Requires an enabled route and a destination other than block.chainid.
    ///      Shares burn replay protection with fundsOut. Charges the source-chain bucket
    ///      and rolling limit, but not global limits. An inflow-only pause does not block it.
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

    /// @notice Updates the `CommissionManager` used for fee quotes and custody.
    ///         Owner-only (MultisigProxy via the typed, timelocked
    ///         `UpdateCommissionManager` operation). Must have deployed code
    ///         and return this Bridge's address from `bridgeAddress()`.
    function setCommissionManager(address newCommissionManager) external;

    /// @notice Updates the minimum accepted `fundsIn` deposit (token smallest
    ///         units). Owner-only (MultisigProxy via the federation
    ///         propose -> timelock -> execute flow). Must be non-zero; reverts
    ///         `InvalidMinFundsInAmount` otherwise.
    /// @dev Must be at least the current `minFundsOutAmount`; otherwise reverts
    ///      `InvalidAmountFloors`. The comparison uses the value at execution.
    function setMinFundsInAmount(uint256 newMinimum) external;

    /// @notice Current minimum accepted `fundsIn` deposit in token smallest
    ///         units. Always non-zero.
    function minFundsInAmount() external view returns (uint256);

    /// @notice Updates the minimum accepted `fundsOut` release (token smallest
    ///         units). Owner-only (MultisigProxy via the federation
    ///         propose -> timelock -> execute flow). Must be non-zero; reverts
    ///         `InvalidMinFundsOutAmount` otherwise.
    /// @dev Must not exceed the current `minFundsInAmount`; otherwise reverts
    ///      `InvalidAmountFloors`. The comparison uses the value at execution.
    function setMinFundsOutAmount(uint256 newMinimum) external;

    /// @notice Current minimum accepted `fundsOut` release in token smallest
    ///         units. Always non-zero.
    /// @dev The outbound counterpart of `minFundsInAmount`. It bounds the flat
    ///      `baseFee` a release route may charge, and independently caps how
    ///      cheap an individual release can be — a swarm of dust releases costs
    ///      the bridge Arbitrum gas and a per-operation source-chain fee that the
    ///      released amount would not cover.
    function minFundsOutAmount() external view returns (uint256);

    /// @notice Configures (or reconfigures) the per-chain outflow token bucket for
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

    /// @notice Configures (or reconfigures) the global (aggregate) outflow token
    ///         bucket that bounds total `fundsOut` across all source chains.
    ///         Owner-only. Same bps semantics, combined burst-plus-refill bound
    ///         (against `MAX_GLOBAL_OUTFLOW_BPS`) and accrue-and-preserve
    ///         behavior as `setOutflowLimit`.
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

    /// @notice Current token-bucket reference for `chainId`, equal to its
    ///         accounted locked liquidity. Rolling-window expiry cannot change
    ///         this value by itself; only an actual liquidity debit, credit, or
    ///         rebalance can do so. The immutable safety limiter separately uses
    ///         `lockedLiquidity + rollingSpent` as its rolling reference.
    function chainOutflowReference(uint256 chainId) external view returns (uint256);

    /// @notice Aggregate token-bucket reference, equal to total accounted
    ///         locked liquidity across all source chains.
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

    /// @notice Current `CommissionManager` Bridge uses for fee quotes and custody.
    function commissionManager() external view returns (ICommissionManager);

    /// @notice Always reverts; ownership cannot be renounced.
    function renounceOwnership() external view;
}
