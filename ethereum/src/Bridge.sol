// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BridgeBase} from "./BridgeBase.sol";
import {IBridge} from "./interfaces/IBridge.sol";
import {ICommissionManager} from "./interfaces/ICommissionManager.sol";
import {IRouteRegistry} from "./interfaces/IRouteRegistry.sol";
import {FundsInContext, FundsOutContext} from "./interfaces/RouteTypes.sol";
import {OutflowRateLimiter} from "./libraries/OutflowRateLimiter.sol";
import {RollingOutflowLimiter} from "./libraries/RollingOutflowLimiter.sol";

/// @title Bridge
/// @notice Production bridge for locking USDT0 on Arbitrum and unlocking it
///         back. Extends BridgeBase with full event data for the UTEXO
///         backend and routes commission to a standalone CommissionManager so
///         protocol fees are held separately from bridge liquidity.
///
/// @dev - Owner is `MultisigProxy`. `fundsOut` is called via
///        `MultisigProxy.fundsOutCall()` (TEE M-of-N).
///      - Route-specific finality verification and per-route settlement
///        accounting (RGB `fundsInRecords` etc.) live behind the
///        `RouteRegistry` dispatcher in dedicated plugin contracts. Bridge
///        only owns: token custody, the common derived `burnId` replay guard,
///        and commission routing.
///      - `fundsIn` has two overloads:
///        • Public 5-arg: any EVM user on this chain can lock tokens; the
///          source chain id is filled with `block.chainid`.
///        • Adapter-only 6-arg: callable only by the trusted `lzAdapter`,
///          which forwards a non-spoofable `sourceChainId` carried in
///          `composeMsg` from the source chain. Both overloads share the
///          same private body via `_fundsIn`.
///      - `lzAdapter` is mutable so federation governance can rotate adapter
///        deployments without redeploying the Bridge.
contract Bridge is BridgeBase, IBridge, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using OutflowRateLimiter for OutflowRateLimiter.Bucket;
    using RollingOutflowLimiter for RollingOutflowLimiter.Window;

    // =========================================================================
    // State
    // =========================================================================

    /// @notice Upper bound on the `destinationAddress` (fundsIn) and
    ///         `sourceAddress` (fundsOut) byte length. These strings are echoed
    ///         into event logs, so an unbounded value would let a caller inflate
    ///         log-storage and indexer cost. 512 bytes covers every supported
    ///         destination representation (RGB invoices and other chains) with
    ///         ample headroom.
    uint256 public constant MAX_ADDRESS_LENGTH = 512;

    /// @notice Upper bound on the `fundsOut` `proof` byte length. `proof` is
    ///         forwarded to the route verifier, so an unbounded blob would let a
    ///         release inflate calldata + verifier gas. 1024 bytes comfortably
    ///         fits the verifier formats (RGB is 64 bytes today; a future SPV
    ///         inclusion proof stays well under this).
    uint256 public constant MAX_PROOF_LENGTH = 1024;

    /// @notice Upper bound on the `settlementData` byte length on both the
    ///         `fundsIn` and `fundsOut` paths. `settlementData` is forwarded to
    ///         the route settlement module, which may decode and iterate it
    ///         (e.g. `RgbSettlementModule.beforeFundsOut` walks the
    ///         `(operationIds, amounts)` arrays it carries), so an unbounded blob
    ///         would let that loop inflate until it exceeds the block gas limit
    ///         and bricks the call. `settlementData` encodes as ~`128 + 64 * n`
    ///         bytes for `n` records, so 4096 bytes admits ~62 records — ample
    ///         headroom while keeping any settlement loop bounded. Enforced on
    ///         `fundsIn` too as defence-in-depth: current inbound modules ignore
    ///         `settlementData`, but a future module could iterate it.
    uint256 public constant MAX_SETTLEMENT_DATA_LENGTH = 4096;

    /// @notice Basis-point denominator for the immutable rolling safety limits.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Headroom allowed between the native value supplied to `fundsIn`
    ///         and the fresh destination-side oracle quote, to absorb ETH/USD
    ///         drift between quoting and execution.
    ///
    ///         Direct deposits may attach up to 5% above the quote as a buffer;
    ///         exactly the quote is collected and the remainder is refunded, so
    ///         the band is one-sided and costs neither party. LayerZero deposits
    ///         carry a source-agreed value that cannot be refunded across
    ///         domains, so there the band is symmetric — 5% either side — and
    ///         whatever arrives inside it is collected in full.
    uint256 public constant NATIVE_COMMISSION_TOLERANCE_BPS = 500;

    /// @notice Minimum rolling interval covered by the immutable safety
    ///         limiter. The bounded ring implementation retains usage for
    ///         24-25 hours, never less than this value.
    uint256 public constant OUTFLOW_SAFETY_WINDOW = 24 hours;

    /// @notice A source chain can move at most 20% of its reference liquidity
    ///         during one rolling safety window. Compile-time constant: neither
    ///         federation governance nor the enclave lane can raise it.
    uint256 public constant MAX_CHAIN_OUTFLOW_BPS = 2_000;

    /// @notice Physical token outflow across all source chains can consume at
    ///         most 20% of global reference TVL during one rolling safety
    ///         window. Compile-time constant and independent of configurable
    ///         token-bucket settings.
    uint256 public constant MAX_GLOBAL_OUTFLOW_BPS = 2_000;

    /// @notice Share denominator for the outflow token buckets. Bucket
    ///         allowance is held in shares of reference liquidity rather than
    ///         absolute token units — `SHARE_UNIT` shares are 100% of the
    ///         reference — so a bucket configured once keeps its meaning as
    ///         liquidity grows or shrinks, with no governance retuning.
    uint256 public constant SHARE_UNIT = 1e18;

    /// @notice Window over which a bucket's `refillBpsPerWindow` accrues in
    ///         full. Compile-time constant: federation cannot shorten it to
    ///         make allowance return faster.
    uint256 public constant BUCKET_REFILL_WINDOW = 24 hours;

    /// @notice Domain-separated type hash for the on-chain `operationId`
    ///         derivation. Binds the id to this contract, the deposit context
    ///         and a formula version, so ids cannot collide across deployments
    ///         or a future formula revision. Not an EIP-712 signing digest —
    ///         it is an internal, unsigned domain separator for the id hash.
    bytes32 public constant FUNDS_IN_OPERATION_TYPEHASH = keccak256(
        "UtexoFundsInOperation(address bridge,uint256 sourceChainId,bytes32 sourceSender,uint256 senderNonce,address token,uint256 grossAmount,uint256 destinationChainId,bytes32 destinationAddressHash,bytes32 settlementDataHash,uint256 chainId)"
    );

    /// @notice Domain-separated type hash for the `fundsOut` replay key.
    ///         Binds common release intent fields to this Bridge deployment and
    ///         formula version, including the exact verifier proof the enclave
    ///         signed for the release.
    bytes32 public constant FUNDS_OUT_BURN_ID_TYPEHASH = keccak256(
        "UtexoFundsOutBurnId(address bridge,uint256 chainId,address token,address recipient,uint256 amount,uint256 sourceChainId,uint256 destinationChainId,bytes32 sourceAddressHash,bytes32 proofHash,bytes32 settlementDataHash)"
    );

    /// @notice Domain-separated type hash for the credit-leg `operationId` of a
    ///         `rebalanceLiquidity` call. Distinct from
    ///         `FUNDS_IN_OPERATION_TYPEHASH` so a rebalance id can never collide
    ///         with a deposit id. Folds in the canonical `burnId` (itself a hash
    ///         of the FULL intent, including the debit-side `proof` and
    ///         `settlementDataOut`), so two rebalances that differ only on the
    ///         debit side — same source/amount/destination but a different burn —
    ///         still derive distinct `operationId`s. Without this, a credit leg
    ///         whose `settlementDataIn` is empty (e.g. RGB→Arch) would collide.
    bytes32 public constant REBALANCE_OPERATION_TYPEHASH = keccak256(
        "UtexoRebalanceOperation(address bridge,uint256 sourceChainId,bytes32 sourceSender,address token,uint256 amount,uint256 destinationChainId,bytes32 destinationAddressHash,bytes32 settlementDataInHash,uint256 burnId,uint256 chainId)"
    );

    /// @notice Domain-separated type hash for the `rebalanceLiquidity` replay
    ///         key. Derived purely from the rebalance intent — no nonce is
    ///         folded in, so it matches `fundsOut`'s replay model exactly: an
    ///         identical intent can never execute twice, while legitimately
    ///         distinct rebalances differ in the intent itself (the destination
    ///         RGB OpId carried in `settlementDataIn` for mint-side credits, or
    ///         the Bitcoin `proof` + referenced records for burn-backed debits).
    bytes32 public constant REBALANCE_BURN_ID_TYPEHASH = keccak256(
        "UtexoRebalanceBurnId(address bridge,uint256 chainId,address token,uint256 amount,uint256 sourceChainId,uint256 destinationChainId,bytes32 sourceAddressHash,bytes32 destinationAddressHash,bytes32 proofHash,bytes32 settlementDataOutHash,bytes32 settlementDataInHash)"
    );

    /// @notice CommissionManager that receives and custodies protocol fees.
    ICommissionManager public immutable commissionManager;

    /// @inheritdoc IBridge
    /// @dev Mutable so federation can rotate registry deployments via
    ///      `UpdateRouteRegistry` governance op without redeploying the
    ///      Bridge.
    address public override routeRegistry;

    /// @inheritdoc IBridge
    address public override lzAdapter;

    /// @notice Set of Bridge-derived burn identifiers already consumed by a
    ///         successful `fundsOut` or `rebalanceLiquidity`. Shared namespace:
    ///         the two paths derive ids under distinct type hashes, and one
    ///         consumed id can never authorise a second release or rebalance.
    mapping(uint256 burnId => bool consumed) public consumedBurnIds;

    /// @notice Per-`(sourceChainId, sourceSender)` monotonic nonce. Folded into
    ///         `operationId` so two otherwise-identical deposits from the same
    ///         sender still produce distinct ids. Incremented once per successful
    ///         `fundsIn`; a downstream revert rolls the increment back.
    mapping(uint256 sourceChainId => mapping(bytes32 sourceSender => uint256 nonce)) public sourceSenderNonces;

    /// @notice Isolated liquidity per non-Arbitrum chain. Tracks the
    ///         net token amount locked on this chain on behalf of a given
    ///         remote chain: `fundsIn` credits the deposit's `destinationChainId`
    ///         bucket, `fundsOut` debits the release's `sourceChainId` bucket.
    ///         A release can therefore never draw more than was actually
    ///         bridged toward that chain.
    mapping(uint256 chainId => uint256 locked) public lockedLiquidity;

    /// @notice Total accounted bridge liquidity across all isolated chain
    ///         buckets. Direct token donations are deliberately excluded so
    ///         they cannot inflate the immutable global safety allowance.
    ///         `fundsIn` increases it, `fundsOut` decreases it and
    ///         `rebalanceLiquidity` preserves it.
    uint256 public totalLockedLiquidity;

    /// @notice Per-source-chain outflow rate limiter. Bounds how fast
    ///         `fundsOut` can drain a single chain's liquidity. The public
    ///         getter exposes raw bucket `tokens`, `capacity`, and `rate` in
    ///         normalized shares, not token units; use `availableOutflow` for
    ///         the current token-denominated allowance.
    mapping(uint256 chainId => OutflowRateLimiter.Bucket) public chainBuckets;

    /// @notice Global (aggregate) outflow rate limiter. Bounds total `fundsOut`
    ///         across all source chains, since a compromised shared TEE could
    ///         otherwise drain every chain's per-chain bucket in the same
    ///         window (aggregate = sum of per-chain caps). Its public getter
    ///         also reports raw normalized-share units; use
    ///         `availableGlobalOutflow` for token units.
    OutflowRateLimiter.Bucket public globalBucket;

    /// @dev Immutable-security rolling usage. Federation-configurable token
    ///      buckets may only make outflow stricter; these windows cannot be
    ///      reconfigured or disabled.
    mapping(uint256 chainId => RollingOutflowLimiter.Window) private _chainSafetyWindows;
    RollingOutflowLimiter.Window private _globalSafetyWindow;

    /// @inheritdoc IBridge
    /// @dev Always non-zero (validated at the constructor and setter). Mutable
    ///      so federation can retune the dust floor via the `MultisigProxy`
    ///      propose -> timelock -> execute flow without redeploying the Bridge.
    uint256 public override minFundsInAmount;

    /// @inheritdoc IBridge
    /// @dev Always non-zero (validated at the constructor and setter). The
    ///      outbound mirror of `minFundsInAmount`, and the bound the
    ///      CommissionManager validates a `FUNDS_OUT` flat `baseFee` against.
    ///      Mutable through the same `MultisigProxy` propose -> timelock ->
    ///      execute flow.
    uint256 public override minFundsOutAmount;

    // =========================================================================
    // Modifiers
    // =========================================================================

    /// @dev Restricts a function to the configured `lzAdapter`. Until
    ///      federation sets a non-zero adapter, the modifier closes the
    ///      function for every caller.
    modifier onlyLZAdapter() {
        if (msg.sender != lzAdapter) revert NotLZAdapter();
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param usdt0_             USDT0 token address on this chain.
    /// @param routeRegistry_     `RouteRegistry` deployment paired with this
    ///                           Bridge.
    /// @param commissionManager_ CommissionManager that receives protocol fees.
    /// @param lzAdapter_         Initial trusted LayerZero adapter; pass
    ///                           `address(0)` if it has not been deployed yet
    ///                           (federation can wire it up later via
    ///                           `setLZAdapter`).
    /// @param minFundsInAmount_  Initial minimum accepted `fundsIn` deposit in
    ///                           token smallest units. Must be non-zero; it can
    ///                           be retuned later via `setMinFundsInAmount`.
    /// @param minFundsOutAmount_ Initial minimum accepted `fundsOut` release in
    ///                           token smallest units. Must be non-zero; it can
    ///                           be retuned later via `setMinFundsOutAmount`.
    constructor(
        address usdt0_,
        address routeRegistry_,
        address payable commissionManager_,
        address lzAdapter_,
        uint256 minFundsInAmount_,
        uint256 minFundsOutAmount_
    ) BridgeBase(usdt0_) {
        if (routeRegistry_ == address(0)) revert InvalidRouteRegistryAddress();
        if (commissionManager_ == address(0)) revert InvalidCommissionManagerAddress();
        if (minFundsInAmount_ == 0) revert InvalidMinFundsInAmount();
        if (minFundsOutAmount_ == 0) revert InvalidMinFundsOutAmount();

        routeRegistry = routeRegistry_;
        commissionManager = ICommissionManager(commissionManager_);
        lzAdapter = lzAdapter_;
        minFundsInAmount = minFundsInAmount_;
        minFundsOutAmount = minFundsOutAmount_;
    }

    // =========================================================================
    // External — admin
    // =========================================================================

    /// @inheritdoc IBridge
    /// @dev Owner is `MultisigProxy`; federation governance gates this call
    ///      on its M-of-N timelock flow. Rotation only — rejects `address(0)`
    ///      so an accidental zero cannot silently close the path; use
    ///      `disableLZAdapter` for an explicit, separately-logged shutdown.
    function setLZAdapter(address newAdapter) external override onlyOwner {
        if (newAdapter == address(0)) revert InvalidLZAdapter();
        address old = lzAdapter;
        lzAdapter = newAdapter;
        emit LZAdapterUpdated(old, newAdapter);
    }

    /// @inheritdoc IBridge
    /// @dev Owner is `MultisigProxy`. Explicit disable, emitting
    ///      `LZAdapterDisabled` so monitoring can tell a shutdown from a
    ///      rotation.
    function disableLZAdapter() external override onlyOwner {
        address old = lzAdapter;
        lzAdapter = address(0);
        emit LZAdapterDisabled(old);
    }

    /// @inheritdoc IBridge
    /// @dev Owner is `MultisigProxy`; federation gates this on its M-of-N
    ///      timelock flow via `proposeUpdateRouteRegistry`.
    function setRouteRegistry(address newRouteRegistry) external override onlyOwner {
        if (newRouteRegistry == address(0)) revert InvalidRouteRegistryAddress();
        address old = routeRegistry;
        routeRegistry = newRouteRegistry;
        emit RouteRegistryUpdated(old, newRouteRegistry);
    }

    /// @inheritdoc IBridge
    /// @dev Owner is `MultisigProxy`; federation gates this on its M-of-N
    ///      timelock flow (generic `proposeAdminExecute` -> execute). Must be
    ///      non-zero: a non-zero floor is what rejects zero-amount and dust
    ///      deposits on the inbound path.
    function setMinFundsInAmount(uint256 newMinimum) external override onlyOwner {
        if (newMinimum == 0) revert InvalidMinFundsInAmount();
        uint256 old = minFundsInAmount;
        minFundsInAmount = newMinimum;
        emit MinFundsInAmountUpdated(old, newMinimum);
    }

    /// @inheritdoc IBridge
    /// @dev Owner is `MultisigProxy`; federation gates this on its M-of-N
    ///      timelock flow (generic `proposeAdminExecute` -> execute). Must be
    ///      non-zero
    function setMinFundsOutAmount(uint256 newMinimum) external override onlyOwner {
        if (newMinimum == 0) revert InvalidMinFundsOutAmount();
        uint256 old = minFundsOutAmount;
        minFundsOutAmount = newMinimum;
        emit MinFundsOutAmountUpdated(old, newMinimum);
    }

    /// @inheritdoc IBridge
    /// @dev Owner is `MultisigProxy`; federation gates this on its timelock flow.
    ///      Validation is liquidity-independent, so a policy can be installed
    ///      before any deposit exists — including at deployment.
    function setOutflowLimit(uint256 chainId, uint256 burstBps, uint256 refillBpsPerWindow)
        external
        override
        onlyOwner
    {
        if (chainId == 0) revert InvalidOutflowLimit();
        _validateOutflowBps(burstBps, refillBpsPerWindow, MAX_CHAIN_OUTFLOW_BPS);

        OutflowRateLimiter.Settings memory cfg = _buildOutflowConfig(burstBps, refillBpsPerWindow);
        OutflowRateLimiter.validate(cfg, false);
        chainBuckets[chainId].configurePrimed(cfg);
        emit OutflowLimitUpdated(chainId, burstBps, refillBpsPerWindow, chainBuckets[chainId].tokens);
    }

    /// @inheritdoc IBridge
    /// @dev Owner is `MultisigProxy`; federation gates this on its timelock flow.
    function setGlobalOutflowLimit(uint256 burstBps, uint256 refillBpsPerWindow) external override onlyOwner {
        _validateOutflowBps(burstBps, refillBpsPerWindow, MAX_GLOBAL_OUTFLOW_BPS);

        OutflowRateLimiter.Settings memory cfg = _buildOutflowConfig(burstBps, refillBpsPerWindow);
        OutflowRateLimiter.validate(cfg, false);
        globalBucket.configurePrimed(cfg);
        emit GlobalOutflowLimitUpdated(burstBps, refillBpsPerWindow, globalBucket.tokens);
    }

    /// @inheritdoc IBridge
    function availableOutflow(uint256 chainId) external view override returns (uint256) {
        uint256 shares = OutflowRateLimiter.currentState(chainBuckets[chainId]).tokens;
        return _fromShares(shares, _chainReference(chainId));
    }

    /// @inheritdoc IBridge
    function availableGlobalOutflow() external view override returns (uint256) {
        uint256 shares = OutflowRateLimiter.currentState(globalBucket).tokens;
        return _fromShares(shares, _globalReference());
    }

    /// @inheritdoc IBridge
    function availableChainSafetyOutflow(uint256 chainId) external view override returns (uint256) {
        uint256 spent = _chainSafetyWindows[chainId].current();
        return _remainingSafetyAllowance(lockedLiquidity[chainId] + spent, spent, MAX_CHAIN_OUTFLOW_BPS);
    }

    /// @inheritdoc IBridge
    function availableGlobalSafetyOutflow() external view override returns (uint256) {
        uint256 spent = _globalSafetyWindow.current();
        return _remainingSafetyAllowance(totalLockedLiquidity + spent, spent, MAX_GLOBAL_OUTFLOW_BPS);
    }

    /// @inheritdoc IBridge
    function chainOutflowReference(uint256 chainId) external view override returns (uint256) {
        return _chainReference(chainId);
    }

    /// @inheritdoc IBridge
    function globalOutflowReference() external view override returns (uint256) {
        return _globalReference();
    }

    /// @inheritdoc IBridge
    function effectiveAvailableOutflow(uint256 chainId) external view override returns (uint256) {
        uint256 chainSpent = _chainSafetyWindows[chainId].current();
        uint256 chainRef = lockedLiquidity[chainId] + chainSpent;
        uint256 globalSpent = _globalSafetyWindow.current();
        uint256 globalRef = totalLockedLiquidity + globalSpent;

        uint256 allowed = lockedLiquidity[chainId];
        allowed =
            Math.min(allowed, _fromShares(OutflowRateLimiter.currentState(chainBuckets[chainId]).tokens, chainRef));
        allowed = Math.min(allowed, _fromShares(OutflowRateLimiter.currentState(globalBucket).tokens, globalRef));
        allowed = Math.min(allowed, _remainingSafetyAllowance(chainRef, chainSpent, MAX_CHAIN_OUTFLOW_BPS));
        allowed = Math.min(allowed, _remainingSafetyAllowance(globalRef, globalSpent, MAX_GLOBAL_OUTFLOW_BPS));
        return allowed;
    }

    // =========================================================================
    // External — user-facing
    // =========================================================================

    /// @inheritdoc IBridge
    function fundsIn(
        uint256 amount,
        uint256 destinationChainId,
        string calldata destinationAddress,
        bytes calldata settlementData
    ) external payable override whenNotPaused nonReentrant returns (bytes32 operationId) {
        // Direct EVM deposit: the source sender IS the caller, so a native
        // surplus can be returned to them — `refundNativeSurplus = true`.
        address caller = _msgSender();
        operationId = _fundsIn(
            caller,
            _toSourceSender(caller),
            amount,
            block.chainid,
            destinationChainId,
            destinationAddress,
            settlementData,
            true
        );
    }

    /// @inheritdoc IBridge
    function fundsIn(
        uint256 amount,
        uint256 sourceChainId,
        bytes32 sourceSender,
        uint256 destinationChainId,
        string calldata destinationAddress,
        bytes calldata settlementData
    ) external payable override whenNotPaused nonReentrant onlyLZAdapter returns (bytes32 operationId) {
        // LZ deposit: tokens are pulled from the adapter (`_msgSender()`), but
        // the identity bound into `operationId` is the authenticated
        // `sourceSender` forwarded from the source-chain entrypoint.
        //
        // `refundNativeSurplus = false`: `msg.value` is the source-agreed
        // `expectedComposeValue`, and the payer lives on the source chain — the
        // adapter is only its courier, so refunding `_msgSender()` would pay the
        // wrong party. The symmetric drift band absorbs the deviation instead.
        operationId = _fundsIn(
            _msgSender(),
            sourceSender,
            amount,
            sourceChainId,
            destinationChainId,
            destinationAddress,
            settlementData,
            false
        );
    }

    // =========================================================================
    // External — owner-only (called via MultisigProxy)
    // =========================================================================

    /// @inheritdoc IBridge
    function fundsOut(FundsOutParams calldata fundsOutParams)
        external
        override
        onlyOwner
        nonReentrant
        whenOutflowNotPaused
    {
        _validateFundsOutParams(fundsOutParams);

        // Common replay guard. Set the flag before any external interaction
        // so a revert anywhere downstream rolls the mark back with the rest
        // of the call.
        if (consumedBurnIds[fundsOutParams.burnId]) revert BurnIdAlreadyConsumed(fundsOutParams.burnId);
        consumedBurnIds[fundsOutParams.burnId] = true;

        // Isolated liquidity: a release may only draw from the liquidity
        // locked for its source chain. Debit before any external interaction so
        // a downstream revert rolls the debit back with the rest of the call.
        // `amount` (gross) matches what was minted on the source side, i.e. the
        // `netAmount` that `_fundsIn` credited to this bucket.
        uint256 srcLiquidity = lockedLiquidity[fundsOutParams.sourceChainId];
        if (fundsOutParams.amount > srcLiquidity) {
            revert InsufficientChainLiquidity(fundsOutParams.sourceChainId, fundsOutParams.amount, srcLiquidity);
        }

        lockedLiquidity[fundsOutParams.sourceChainId] = srcLiquidity - fundsOutParams.amount;
        uint256 totalLiquidity = totalLockedLiquidity;
        totalLockedLiquidity = totalLiquidity - fundsOutParams.amount;

        // Reference liquidity for both limiter layers: pre-debit liquidity plus
        // usage already recorded in the rolling window. That sum is invariant as
        // releases drain liquidity inside one window, so a sequence of small
        // withdrawals cannot geometrically outpace the ceiling. Both the token
        // buckets and the immutable safety limits below are denominated against
        // the SAME reference, so the two layers never disagree about what a
        // percentage means.
        uint256 chainSpent = _chainSafetyWindows[fundsOutParams.sourceChainId].current();
        uint256 chainReference = srcLiquidity + chainSpent;
        uint256 globalSpent = _globalSafetyWindow.current();
        uint256 globalReference = totalLiquidity + globalSpent;

        // Outflow rate limit. Consume both the per-source-chain
        // bucket and the global aggregate bucket; either being short reverts the
        // whole call (and rolls back the consume above). Both are debited before
        // any external interaction, so a downstream revert restores them too.
        // Per-source-chain bucket (token-scoped errors), then the global
        // aggregate bucket (aggregate-scoped errors via the address(0) sentinel).
        // The limiter is fail-closed: an unconfigured chain/global bucket
        // rejects the release instead of falling back to unlimited outflow.
        // Amounts are converted to shares of the reference, so a bucket keeps
        // its configured percentage meaning as liquidity moves.
        chainBuckets[fundsOutParams.sourceChainId].spend(_toShares(fundsOutParams.amount, chainReference), TOKEN);
        globalBucket.spend(_toShares(fundsOutParams.amount, globalReference), address(0));

        // Quote commission. NATIVE on fundsOut is unrepresentable: the
        // CommissionManager setters reject a (NATIVE, FUNDS_OUT) rule at config,
        // so `nativeCommission` is always 0 on this path. The value is ignored here.
        (uint256 tokenCommission,, uint256 netAmount) = commissionManager.calculateFundsOutCommission(
            fundsOutParams.sourceChainId, fundsOutParams.destinationChainId, TOKEN, fundsOutParams.amount
        );

        // Delegate route-specific finality verification + settlement-state
        // mutation to the configured plugins. The registry runs the verifier
        // (view-only) first; if it reverts, no settlement-module write happens.
        IRouteRegistry(routeRegistry)
            .beforeFundsOut(
                FundsOutContext({
                token: TOKEN,
                recipient: fundsOutParams.recipient,
                amount: fundsOutParams.amount,
                burnId: fundsOutParams.burnId,
                sourceChainId: fundsOutParams.sourceChainId,
                destChainId: fundsOutParams.destinationChainId,
                sourceAddress: fundsOutParams.sourceAddress,
                isRebalance: false
            }),
                fundsOutParams.proof,
                fundsOutParams.settlementData
            );

        // Immutable TVL-relative safety limits. These aggregate every release
        // over a rolling 24h+ window, so neither one full-pool transaction nor a
        // same-window sequence of smaller transactions can bypass the ceiling.
        // They run after the existing bucket and route checks to preserve those
        // paths' fail-fast errors; any failure here still atomically rolls back
        // all earlier state and plugin calls.
        _consumeChainSafetyOutflow(fundsOutParams.sourceChainId, chainSpent, chainReference, fundsOutParams.amount);
        _consumeGlobalSafetyOutflow(globalSpent, globalReference, fundsOutParams.amount);

        // Forward token commission to the CommissionManager pool.
        if (tokenCommission != 0) _forwardTokenCommission(tokenCommission);

        // Deliver the net amount to the recipient.
        IERC20(TOKEN).safeTransfer(fundsOutParams.recipient, netAmount);

        emit BridgeFundsOut(
            fundsOutParams.recipient,
            fundsOutParams.amount,
            netAmount,
            tokenCommission,
            fundsOutParams.burnId,
            fundsOutParams.sourceChainId,
            fundsOutParams.destinationChainId,
            fundsOutParams.sourceAddress
        );
    }

    /// @inheritdoc IBridge
    /// @dev Accounting-only bucket migration; no token transfer, no commission.
    ///      Composition of the two existing legs:
    ///        debit  = `fundsOut` minus the payout: replay guard, per-chain
    ///                 rate limit, bucket debit, route verifier + settlement
    ///                 check (`beforeFundsOut`);
    ///        credit = `_fundsIn` minus the token pull: on-chain `operationId`,
    ///                 settlement write (`onFundsIn`), bucket credit,
    ///                 conditional RGB-only `FundsIn` event.
    ///      Both legs dispatch on the same `(sourceChainId, destinationChainId)`
    ///      route, so a rebalance pair must be explicitly enabled in the
    ///      registry with plugins fitting both directions.
    ///      State mutations happen before the external registry calls, so a
    ///      revert in either plugin rolls everything back atomically.
    function rebalanceLiquidity(RebalanceParams calldata params)
        external
        override
        onlyOwner
        nonReentrant
        whenOutflowNotPaused
    {
        _validateRebalanceParams(params);

        // Credit-leg identity: the hash of the source-chain address string. Only
        // used to derive the credit `operationId` and label the event; unlike
        // `_fundsIn`, no nonce stream is consumed here (see the replay guard).
        bytes32 sourceSender = _hashCalldataString(params.sourceAddress);

        // Replay guard, same model as `fundsOut`: the caller-supplied id must
        // equal the canonical hash of the full intent, and a consumed id can
        // never execute again. No nonce is folded in — an identical intent can
        // therefore never run twice, exactly as `fundsOut` behaves. Legitimately
        // distinct rebalances differ in the intent itself: the destination RGB
        // OpId in `settlementDataIn` (mint-side credit) or the Bitcoin proof +
        // referenced records in `proof`/`settlementDataOut` (burn-backed debit).
        // True single-burn uniqueness (one RGB burn settled at most once across
        // fundsOut and rebalance combined) is NOT provable on-chain — the proof
        // only attests a Bitcoin block exists — and remains the enclave's
        // responsibility, the same accepted residual as the RGB→EVM fundsOut
        // path.
        uint256 expectedBurnId = _deriveRebalanceBurnId(params);
        if (params.burnId != expectedBurnId) revert InvalidBurnId(params.burnId, expectedBurnId);
        if (consumedBurnIds[params.burnId]) revert BurnIdAlreadyConsumed(params.burnId);
        consumedBurnIds[params.burnId] = true;

        // Debit leg: the migration may only draw from the liquidity locked for
        // its source chain — identical to the `fundsOut` solvency rule.
        uint256 srcLiquidity = lockedLiquidity[params.sourceChainId];
        if (params.amount > srcLiquidity) {
            revert InsufficientChainLiquidity(params.sourceChainId, params.amount, srcLiquidity);
        }

        lockedLiquidity[params.sourceChainId] = srcLiquidity - params.amount;

        // Per-source-chain outflow rate limit: release capacity is migrating
        // away from this chain, so it spends the chain bucket like a release.
        // The global bucket is intentionally NOT spent — it bounds physical
        // token egress, and no tokens leave here; the eventual exit pays the
        // global bucket inside `fundsOut`. Same reference as the immutable
        // per-chain safety limit consumed below.
        uint256 chainSpent = _chainSafetyWindows[params.sourceChainId].current();
        uint256 chainReference = srcLiquidity + chainSpent;
        chainBuckets[params.sourceChainId].spend(_toShares(params.amount, chainReference), TOKEN);

        // Debit-leg verification: route verifier (view-only source proof)
        // first, then the settlement module's release check. `recipient` is
        // this Bridge — the backing never leaves custody.
        IRouteRegistry(routeRegistry)
            .beforeFundsOut(
                FundsOutContext({
                token: TOKEN,
                recipient: address(this),
                amount: params.amount,
                burnId: params.burnId,
                sourceChainId: params.sourceChainId,
                destChainId: params.destinationChainId,
                sourceAddress: params.sourceAddress,
                isRebalance: true
            }),
                params.proof,
                params.settlementDataOut
            );

        // Credit leg: canonical id + settlement write. For RGB destinations the
        // module records `fundsInRecords[operationId] = amount` and returns the
        // RGB OpId — indistinguishable from a real deposit to the RGB side.
        bytes32 operationId = _deriveRebalanceOperationId(params, sourceSender, expectedBurnId);
        uint256 rgbOpId = IRouteRegistry(routeRegistry)
            .onFundsIn(
                FundsInContext({
                token: TOKEN,
                sender: _msgSender(),
                sourceSender: sourceSender,
                grossAmount: params.amount,
                netAmount: params.amount,
                operationId: operationId,
                senderNonce: 0, // rebalance consumes no nonce stream; id is nonce-free
                sourceChainId: params.sourceChainId,
                destChainId: params.destinationChainId,
                destAddress: params.destinationAddress
            }),
                params.settlementDataIn
            );

        lockedLiquidity[params.destinationChainId] += params.amount;

        // Rebalance moves release capacity away from the source chain and
        // therefore consumes the same immutable per-chain safety allowance as a
        // physical release. It intentionally does not consume global allowance:
        // no token leaves custody, and the eventual fundsOut will consume it.
        // Kept after route validation so route-specific errors retain priority;
        // a safety-limit revert rolls the complete rebalance back atomically.
        _consumeChainSafetyOutflow(params.sourceChainId, chainSpent, chainReference, params.amount);

        // RGB-only correlation event, same contract as `_fundsIn`: the RGB
        // listener authorises a mint against `FundsIn` and needs no awareness
        // of the rebalance mechanics.
        if (rgbOpId != 0) emit FundsIn(_msgSender(), rgbOpId, params.amount);
        emit BridgeRebalance(
            operationId,
            params.burnId,
            params.sourceChainId,
            params.destinationChainId,
            params.amount,
            params.sourceAddress,
            params.destinationAddress
        );
    }

    /// @inheritdoc IBridge
    function renounceOwnership() public view override(BridgeBase, IBridge) onlyOwner {
        revert RenounceOwnershipBlocked();
    }

    // =========================================================================
    // Internal
    // =========================================================================

    function _validateFundsOutParams(FundsOutParams calldata params) private view {
        if (params.amount == 0) revert ZeroAmount();
        if (params.amount < minFundsOutAmount) revert AmountBelowMinimum(params.amount, minFundsOutAmount);
        if (params.recipient == address(0)) revert InvalidRecipientAddress();
        if (params.sourceChainId == 0) revert InvalidSourceChainId();
        if (params.destinationChainId == 0) revert InvalidDestinationChainId();

        uint256 sourceAddressLength = bytes(params.sourceAddress).length;
        if (sourceAddressLength > MAX_ADDRESS_LENGTH) {
            revert AddressTooLong(sourceAddressLength, MAX_ADDRESS_LENGTH);
        }
        if (params.proof.length > MAX_PROOF_LENGTH) revert ProofTooLong(params.proof.length, MAX_PROOF_LENGTH);
        if (params.settlementData.length > MAX_SETTLEMENT_DATA_LENGTH) {
            revert SettlementDataTooLong(params.settlementData.length, MAX_SETTLEMENT_DATA_LENGTH);
        }
        if (params.amount > IERC20(TOKEN).balanceOf(address(this))) revert AmountExceedBridgePool();

        uint256 expectedBurnId = _deriveBurnId(params);
        if (params.burnId != expectedBurnId) revert InvalidBurnId(params.burnId, expectedBurnId);
    }

    function _validateRebalanceParams(RebalanceParams calldata params) private pure {
        if (params.amount == 0) revert ZeroAmount();
        if (params.sourceChainId == 0) revert InvalidSourceChainId();
        if (params.destinationChainId == 0) revert InvalidDestinationChainId();
        if (params.sourceChainId == params.destinationChainId) revert RebalanceSameChain(params.sourceChainId);
        if (bytes(params.destinationAddress).length == 0) revert InvalidDestinationAddress();

        uint256 sourceAddressLength = bytes(params.sourceAddress).length;
        if (sourceAddressLength > MAX_ADDRESS_LENGTH) {
            revert AddressTooLong(sourceAddressLength, MAX_ADDRESS_LENGTH);
        }
        uint256 destinationAddressLength = bytes(params.destinationAddress).length;
        if (destinationAddressLength > MAX_ADDRESS_LENGTH) {
            revert AddressTooLong(destinationAddressLength, MAX_ADDRESS_LENGTH);
        }
        if (params.proof.length > MAX_PROOF_LENGTH) revert ProofTooLong(params.proof.length, MAX_PROOF_LENGTH);
        if (params.settlementDataOut.length > MAX_SETTLEMENT_DATA_LENGTH) {
            revert SettlementDataTooLong(params.settlementDataOut.length, MAX_SETTLEMENT_DATA_LENGTH);
        }
        if (params.settlementDataIn.length > MAX_SETTLEMENT_DATA_LENGTH) {
            revert SettlementDataTooLong(params.settlementDataIn.length, MAX_SETTLEMENT_DATA_LENGTH);
        }
    }

    /// @dev Canonical rebalance replay key = domain-separated hash of the full
    ///      rebalance intent (no nonce). Encoded in two `abi.encode` halves
    ///      joined with `bytes.concat` (every field is one 32-byte word; dynamic
    ///      fields are pre-hashed), keeping each half shallow enough to compile
    ///      without the optimizer.
    function _deriveRebalanceBurnId(RebalanceParams calldata params) private view returns (uint256) {
        return uint256(
            keccak256(
                bytes.concat(
                    abi.encode(
                        REBALANCE_BURN_ID_TYPEHASH,
                        address(this),
                        block.chainid,
                        TOKEN,
                        params.amount,
                        params.sourceChainId,
                        params.destinationChainId
                    ),
                    abi.encode(
                        _hashCalldataString(params.sourceAddress),
                        _hashCalldataString(params.destinationAddress),
                        _hashCalldataBytes(params.proof),
                        _hashCalldataBytes(params.settlementDataOut),
                        _hashCalldataBytes(params.settlementDataIn)
                    )
                )
            )
        );
    }

    /// @dev Canonical credit-leg `operationId` for a rebalance. Mirrors
    ///      `_deriveOperationId` under a distinct type hash (no nonce) and folds
    ///      in the validated `burnId`, so a rebalance id can never collide with a
    ///      deposit id, is unique per rebalance intent (even when only the debit
    ///      side differs), and the backend can precompute it from the intent
    ///      alone. `burnId` is passed in already validated against the params.
    function _deriveRebalanceOperationId(RebalanceParams calldata params, bytes32 sourceSender, uint256 burnId)
        private
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                REBALANCE_OPERATION_TYPEHASH,
                address(this),
                params.sourceChainId,
                sourceSender,
                TOKEN,
                params.amount,
                params.destinationChainId,
                _hashCalldataString(params.destinationAddress),
                _hashCalldataBytes(params.settlementDataIn),
                burnId,
                block.chainid
            )
        );
    }

    /// @dev Translate a basis-point policy into the limiter's share-denominated
    ///      settings. `capacity` is the burst expressed in shares of reference
    ///      liquidity, `rate` the per-second share accrual that fills
    ///      `refillBpsPerWindow` over one `BUCKET_REFILL_WINDOW`. Integer
    ///      division rounds the rate down, so exact-window refill is
    ///      conservative by less than one share-per-second remainder.
    ///      Both fit in uint128 by construction: the largest representable
    ///      capacity is `SHARE_UNIT` (1e18) and rate is strictly smaller, so the
    ///      absolute-amount overflow check the old signature needed is gone.
    ///      Precision lives in `SHARE_UNIT`, not in a carried remainder: at
    ///      1500 bps the truncated rate loses ~6e-14 relative per second, which
    ///      is why no fractional-remainder accounting is required.
    ///      `OutflowRateLimiter.validate` then enforces `0 < rate < capacity`.
    function _buildOutflowConfig(uint256 burstBps, uint256 refillBpsPerWindow)
        private
        pure
        returns (OutflowRateLimiter.Settings memory)
    {
        uint256 capacityShares = Math.mulDiv(burstBps, SHARE_UNIT, BPS_DENOMINATOR);
        uint256 rateShares = Math.mulDiv(refillBpsPerWindow, SHARE_UNIT, BPS_DENOMINATOR) / BUCKET_REFILL_WINDOW;
        return OutflowRateLimiter.Settings({
            isEnabled: true,
            // forge-lint: disable-next-line(unsafe-typecast)
            capacity: uint128(capacityShares),
            // forge-lint: disable-next-line(unsafe-typecast)
            rate: uint128(rateShares)
        });
    }

    /// @dev Shared body for both `fundsIn` overloads. Derives the canonical
    ///      `operationId` on-chain (never caller-supplied) and returns it.
    /// @param from         EVM caller tokens are pulled from (user, or adapter).
    /// @param sourceSender Original source-chain sender bound into `operationId`.
    function _fundsIn(
        address from,
        bytes32 sourceSender,
        uint256 amount,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string memory destinationAddress,
        bytes calldata settlementData,
        bool refundNativeSurplus
    ) private returns (bytes32 operationId) {
        if (amount < minFundsInAmount) {
            revert AmountBelowMinimum(amount, minFundsInAmount);
        }
        if (bytes(destinationAddress).length == 0) revert InvalidDestinationAddress();
        if (bytes(destinationAddress).length > MAX_ADDRESS_LENGTH) {
            revert AddressTooLong(bytes(destinationAddress).length, MAX_ADDRESS_LENGTH);
        }
        if (settlementData.length > MAX_SETTLEMENT_DATA_LENGTH) {
            revert SettlementDataTooLong(settlementData.length, MAX_SETTLEMENT_DATA_LENGTH);
        }
        if (sourceChainId == 0) revert InvalidSourceChainId();
        if (destinationChainId == 0) revert InvalidDestinationChainId();

        // Commission is freshly quoted from the nominal `amount`. For direct
        // calls `msg.value` is the user's submitted quote; for LayerZero it is
        // the source-agreed expectedComposeValue authenticated by the adapter.
        // The nominal net is intentionally discarded — the credited net is
        // derived from the ACTUAL received amount after the transfer.
        (uint256 tokenCommission, uint256 nativeCommission,) =
            commissionManager.calculateFundsInCommission(sourceChainId, destinationChainId, TOKEN, amount);

        // Bound `msg.value` against the fresh quote, then decide how much of it
        // is actually commission. Both paths accept the same 5% headroom above
        // the quote; they differ in what happens to that headroom, because only
        // one of them can pay it back.
        //
        //  - Direct deposit (`refundNativeSurplus`): the surplus is a drift
        //    buffer. The floor is the quote itself and exactly the quote is
        //    collected, so the protocol never under-collects and the caller is
        //    never charged more than quoted — the surplus is returned below.
        //  - LZ deposit: the payer is on the source chain and unreachable, so no
        //    refund is possible. A symmetric band absorbs drift in both
        //    directions and the whole source-agreed value is collected.
        //
        // TOKEN-commission routes (nativeCommission == 0) still accept no native.
        // `minimum` and `nativeToCollect` are set together per branch on purpose:
        // the trailing refund computes `msg.value - nativeToCollect`, so a floor
        // below what is collected would underflow. Pairing them here makes that
        // invariant structural rather than something a later edit must remember.
        uint256 nativeToCollect;
        if (nativeCommission == 0) {
            if (msg.value != 0) revert NativeValueMismatch();
        } else {
            uint256 minimum;
            if (refundNativeSurplus) {
                minimum = nativeCommission;
                nativeToCollect = nativeCommission;
            } else {
                minimum = Math.mulDiv(
                    nativeCommission,
                    BPS_DENOMINATOR - NATIVE_COMMISSION_TOLERANCE_BPS,
                    BPS_DENOMINATOR,
                    Math.Rounding.Ceil
                );
                nativeToCollect = msg.value;
            }
            uint256 maximum =
                Math.mulDiv(nativeCommission, BPS_DENOMINATOR + NATIVE_COMMISSION_TOLERANCE_BPS, BPS_DENOMINATOR);
            if (msg.value < minimum || msg.value > maximum) {
                revert NativeCommissionOutOfBounds(msg.value, minimum, maximum);
            }
        }

        // Build the canonical context. The per-`(sourceChainId, sourceSender)`
        // nonce is consumed here — before any external call, so a downstream
        // revert rolls it back — and folded, with the deposit context, into the
        // on-chain-derived operationId. Because the id binds the authenticated
        // `sourceSender` and an incrementing nonce, a third party cannot predict
        // or pre-empt it. Held in memory to keep the stack shallow.
        FundsInContext memory ctx = FundsInContext({
            token: TOKEN,
            sender: from,
            sourceSender: sourceSender,
            grossAmount: amount,
            netAmount: 0, // set below from the ACTUAL received amount
            operationId: bytes32(0), // filled in on the next line
            senderNonce: sourceSenderNonces[sourceChainId][sourceSender]++,
            sourceChainId: sourceChainId,
            destChainId: destinationChainId,
            destAddress: destinationAddress
        });
        // operationId binds grossAmount (not netAmount), so it is stable
        // regardless of any token transfer fee.
        ctx.operationId = _deriveOperationId(ctx, settlementData);

        // Pull the gross amount and measure what ACTUALLY arrived. A
        // fee-on-transfer token can deliver less than `amount`; crediting the
        // nominal amount would overstate custody and could brick release of the
        // recorded balance. Everything downstream — records, isolated
        // liquidity, event — is built from `received`, never from `amount`.
        uint256 balanceBefore = IERC20(TOKEN).balanceOf(address(this));
        IERC20(TOKEN).safeTransferFrom(from, address(this), amount);
        uint256 received = IERC20(TOKEN).balanceOf(address(this)) - balanceBefore;

        // The token commission is forwarded out of `received`; guard the
        // subtraction so a token fee that consumes all (or more) of the actual
        // receipt reverts instead of creating a zero-net settlement or
        // underflowing. Equality is reachable with fee-on-transfer tokens even
        // though the nominal commission configuration is strictly below 100%.
        if (received <= tokenCommission) revert InsufficientReceived(received, tokenCommission);
        ctx.netAmount = received - tokenCommission;

        // Forward token commission BEFORE the settlement hook so that any
        // external call the hook makes (or a contract reading `getContractBalance`
        // during it) observes only the net amount the Bridge actually retains,
        // never the in-flight commission about to leave. `netAmount` is
        // already fixed above, so the hook does not depend on the tokens still
        // being held here.
        if (tokenCommission != 0) _forwardTokenCommission(tokenCommission);

        // Delegate per-route inbound bookkeeping. The module returns an optional
        // correlation id (the RGB OpId for the RGB route; 0 otherwise) to surface
        // in the RGB-only `FundsIn` event below.
        uint256 rgbOpId = IRouteRegistry(routeRegistry).onFundsIn(ctx, settlementData);

        // Isolated liquidity: credit the net deposit to its destination
        // chain's bucket. A later `fundsOut` from that chain can release at most
        // the accumulated locked liquidity. Credited from the ACTUAL received
        // amount so the ledger can never exceed real custody.
        lockedLiquidity[destinationChainId] += ctx.netAmount;
        totalLockedLiquidity += ctx.netAmount;

        // Forward the native commission actually owed — exactly the fresh quote
        // on the direct path, the bounded source-agreed value on the LZ path.
        // Any remainder is returned to the caller at the end of this function,
        // so no native is ever retained in Bridge.
        if (nativeToCollect != 0) {
            (bool ok,) = address(commissionManager).call{value: nativeToCollect}("");
            if (!ok) revert NativeValueMismatch();
        }

        // RGB-only correlation event: emitted only when the route module
        // returned a non-zero external id (the RGB OpId). Other routes skip it.
        if (rgbOpId != 0) emit FundsIn(ctx.sender, rgbOpId, ctx.netAmount);
        emit BridgeFundsIn(
            ctx.operationId,
            ctx.sourceSender,
            ctx.sender,
            ctx.senderNonce,
            ctx.grossAmount,
            ctx.netAmount,
            tokenCommission,
            nativeToCollect, // native commission actually credited to the pool
            ctx.sourceChainId,
            ctx.destChainId,
            ctx.destAddress
        );

        // Return the drift buffer LAST: after every state write and after the
        // commission transfer, so the recipient's fallback observes only settled
        // state. Reachable on the direct path only — the LZ path collects its
        // whole source-agreed value, leaving nothing to refund. The overloads are
        // `nonReentrant`, so this trailing call cannot re-enter.
        uint256 surplus = msg.value - nativeToCollect;
        if (surplus != 0) {
            (bool refunded,) = payable(from).call{value: surplus}("");
            if (!refunded) revert NativeRefundFailed(from, surplus);
        }

        operationId = ctx.operationId;
    }

    /// @dev Left-pads an EVM address into the `bytes32` source-sender encoding
    ///      used by `operationId` derivation and the LZ overload.
    function _toSourceSender(address account) private pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    /// @dev Transfer `amount` of TOKEN to the CommissionManager and credit the
    ///      commission pool by the ACTUAL balance increase this transfer caused.
    ///      Measuring the delta here (rather than in CM from `balanceOf - pool`)
    ///      keeps the credit fee-on-transfer safe and prevents any pre-existing /
    ///      unsolicited direct transfer to CM from being absorbed as commission.
    function _forwardTokenCommission(uint256 amount) private {
        address cm = address(commissionManager);
        uint256 balBefore = IERC20(TOKEN).balanceOf(cm);
        IERC20(TOKEN).safeTransfer(cm, amount);
        uint256 credited = IERC20(TOKEN).balanceOf(cm) - balBefore;
        commissionManager.receiveTokenCommission(TOKEN, credited);
    }

    /// @dev Consume immutable per-chain rolling allowance. `reference` is
    ///      `pre-debit liquidity + already spent`, which stays constant while
    ///      releases consume liquidity inside the same window. This prevents a
    ///      sequence of individually-small withdrawals from geometrically
    ///      draining the bucket.
    function _consumeChainSafetyOutflow(uint256 chainId, uint256 spent, uint256 refLiquidity, uint256 amount) private {
        uint256 limit = _safetyLimit(refLiquidity, MAX_CHAIN_OUTFLOW_BPS);
        if (spent + amount > limit) revert ChainSafetyLimitExceeded(chainId, amount, spent, limit);

        uint256 updatedSpent = _chainSafetyWindows[chainId].consume(amount);
        emit ChainSafetyOutflowConsumed(chainId, amount, updatedSpent, limit);
    }

    /// @dev Consume immutable aggregate rolling allowance for physical token
    ///      outflow. Rebalances do not call this function.
    function _consumeGlobalSafetyOutflow(uint256 spent, uint256 refLiquidity, uint256 amount) private {
        uint256 limit = _safetyLimit(refLiquidity, MAX_GLOBAL_OUTFLOW_BPS);
        if (spent + amount > limit) revert GlobalSafetyLimitExceeded(amount, spent, limit);

        uint256 updatedSpent = _globalSafetyWindow.consume(amount);
        emit GlobalSafetyOutflowConsumed(amount, updatedSpent, limit);
    }

    /// @dev Validate a bucket policy. Deliberately liquidity-independent so a
    ///      policy can be installed at deployment, before the first deposit —
    ///      a percentage needs no reference to be well-formed.
    ///
    ///      The combined burst plus full-window refill budget cannot exceed
    ///      `maxBps`. This makes both a full-TVL instant bucket and an
    ///      over-permissive burst/refill pair unrepresentable, independently of
    ///      current liquidity. The immutable rolling limiter remains the
    ///      non-configurable backstop and no bucket policy can relax it.
    function _validateOutflowBps(uint256 burstBps, uint256 refillBpsPerWindow, uint256 maxBps) private pure {
        if (
            burstBps == 0 || refillBpsPerWindow == 0 || burstBps > maxBps || refillBpsPerWindow > maxBps
                || burstBps + refillBpsPerWindow > maxBps
        ) {
            revert InvalidOutflowPolicy(burstBps, refillBpsPerWindow, maxBps);
        }
    }

    /// @dev Convert a token amount to bucket shares of `reference`. Rounds up so
    ///      a release can never be cheaper in shares than its true fraction of
    ///      the reference, and so dust cannot pass for free.
    function _toShares(uint256 amount, uint256 refLiquidity) private pure returns (uint256) {
        // Unreachable via `fundsOut`/`rebalanceLiquidity`: both revert with
        // `InsufficientChainLiquidity` before this point when the reference is
        // zero. Asserted rather than assumed — division safety must not depend
        // on an upstream caller's ordering.
        if (refLiquidity == 0) revert ZeroOutflowReference();
        return Math.mulDiv(amount, SHARE_UNIT, refLiquidity, Math.Rounding.Ceil);
    }

    /// @dev Convert bucket shares back to token units for the public views.
    function _fromShares(uint256 shares, uint256 refLiquidity) private pure returns (uint256) {
        return Math.mulDiv(shares, refLiquidity, SHARE_UNIT);
    }

    /// @dev Reference liquidity for a source chain: accounted liquidity plus
    ///      usage still counted in the rolling window.
    function _chainReference(uint256 chainId) private view returns (uint256) {
        return lockedLiquidity[chainId] + _chainSafetyWindows[chainId].current();
    }

    /// @dev Reference liquidity for the aggregate scope.
    function _globalReference() private view returns (uint256) {
        return totalLockedLiquidity + _globalSafetyWindow.current();
    }

    function _remainingSafetyAllowance(uint256 refLiquidity, uint256 spent, uint256 maxBps)
        private
        pure
        returns (uint256)
    {
        uint256 limit = _safetyLimit(refLiquidity, maxBps);
        return spent < limit ? limit - spent : 0;
    }

    function _safetyLimit(uint256 refLiquidity, uint256 maxBps) private pure returns (uint256) {
        return Math.mulDiv(refLiquidity, maxBps, BPS_DENOMINATOR);
    }

    /// @dev Canonical `operationId` = domain-separated hash of the deposit
    ///      context. Binds the id to sender/gross-amount/route/destination so it
    ///      is both unpredictable (via the authenticated `sourceSender` + nonce)
    ///      and provably tied to this deposit. Uses `grossAmount` (the user's
    ///      submitted amount, known before execution) rather than the
    ///      commission-derived `netAmount`, so a backend can best-effort
    ///      pre-compute the id; the canonical value is still the one in the
    ///      `BridgeFundsIn` event. `ctx.operationId` is ignored (zero when called).
    function _deriveOperationId(FundsInContext memory ctx, bytes calldata settlementData)
        private
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                FUNDS_IN_OPERATION_TYPEHASH,
                address(this),
                ctx.sourceChainId,
                ctx.sourceSender,
                ctx.senderNonce,
                TOKEN,
                ctx.grossAmount,
                ctx.destChainId,
                keccak256(bytes(ctx.destAddress)),
                keccak256(settlementData),
                block.chainid
            )
        );
    }

    /// @dev Canonical `burnId` = domain-separated hash of the release intent.
    ///      Route-specific burn identity should be placed in `settlementData`
    ///      when a route has one; Bridge commits to it via `settlementDataHash`.
    function _deriveBurnId(FundsOutParams calldata params) private view returns (uint256) {
        return _deriveBurnIdFromFields(
            params.recipient,
            params.amount,
            params.sourceChainId,
            params.destinationChainId,
            params.sourceAddress,
            params.proof,
            params.settlementData
        );
    }

    function _deriveBurnIdFromFields(
        address recipient,
        uint256 amount,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string calldata sourceAddress,
        bytes calldata proof,
        bytes calldata settlementData
    ) private view returns (uint256) {
        return uint256(
            keccak256(
                abi.encode(
                    FUNDS_OUT_BURN_ID_TYPEHASH,
                    address(this),
                    block.chainid,
                    TOKEN,
                    recipient,
                    amount,
                    sourceChainId,
                    destinationChainId,
                    _hashCalldataString(sourceAddress),
                    _hashCalldataBytes(proof),
                    _hashCalldataBytes(settlementData)
                )
            )
        );
    }

    function _hashCalldataString(string calldata value) private pure returns (bytes32 result) {
        assembly {
            let ptr := mload(0x40)
            calldatacopy(ptr, value.offset, value.length)
            result := keccak256(ptr, value.length)
            mstore(0x40, add(ptr, and(add(value.length, 0x3f), not(0x1f))))
        }
    }

    function _hashCalldataBytes(bytes calldata value) private pure returns (bytes32 result) {
        assembly {
            let ptr := mload(0x40)
            calldatacopy(ptr, value.offset, value.length)
            result := keccak256(ptr, value.length)
            mstore(0x40, add(ptr, and(add(value.length, 0x3f), not(0x1f))))
        }
    }
}
